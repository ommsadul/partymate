// Supabase Edge Function: sends an Apple push notification when a message or match is created.
//
// Wire it up with two Database Webhooks (Dashboard > Database > Webhooks):
//   - table `messages`, event INSERT  -> this function
//   - table `matches`,  event INSERT  -> this function
//
// Secrets to set (Dashboard > Edge Functions > send-push > Secrets, or `supabase secrets set`):
//   APNS_TEAM_ID      Apple Developer Team ID (10 characters)
//   APNS_KEY_ID       The Key ID of your APNs auth key (.p8)
//   APNS_PRIVATE_KEY  Contents of the .p8 file (keep the BEGIN/END lines, newlines as \n)
//   APNS_BUNDLE_ID    The app's bundle identifier
//   APNS_ENVIRONMENT  "sandbox" while developing, "production" for the App Store
//
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import { createClient } from "npm:@supabase/supabase-js@2";
import { SignJWT, importPKCS8 } from "npm:jose@5";

type WebhookPayload = {
  type: "INSERT" | "UPDATE" | "DELETE";
  table: string;
  record: Record<string, unknown>;
};

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const teamId = Deno.env.get("APNS_TEAM_ID")!;
const keyId = Deno.env.get("APNS_KEY_ID")!;
const bundleId = Deno.env.get("APNS_BUNDLE_ID")!;
const privateKeyPem = (Deno.env.get("APNS_PRIVATE_KEY") ?? "").replace(/\\n/g, "\n");
const apnsHost = Deno.env.get("APNS_ENVIRONMENT") === "production"
  ? "https://api.push.apple.com"
  : "https://api.sandbox.push.apple.com";

// APNs wants a short-lived JWT signed with the .p8 key. Reuse it for up to 50 minutes.
let cachedToken: { value: string; issuedAt: number } | null = null;
async function apnsToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && now - cachedToken.issuedAt < 50 * 60) return cachedToken.value;
  const key = await importPKCS8(privateKeyPem, "ES256");
  const value = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyId })
    .setIssuer(teamId)
    .setIssuedAt(now)
    .sign(key);
  cachedToken = { value, issuedAt: now };
  return value;
}

async function sendToUser(userId: string, title: string, body: string, data: Record<string, string>) {
  const { data: tokens } = await supabase
    .from("device_tokens")
    .select("token")
    .eq("user_id", userId);
  if (!tokens?.length) return;

  const jwt = await apnsToken();
  const payload = JSON.stringify({ aps: { alert: { title, body }, sound: "default" }, ...data });

  await Promise.all(tokens.map(async ({ token }) => {
    const response = await fetch(`${apnsHost}/3/device/${token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": bundleId,
        "apns-push-type": "alert",
        "apns-priority": "10",
      },
      body: payload,
    });
    // Apple returns 410 when a token is no longer valid; forget it.
    if (response.status === 410 || response.status === 400) {
      await supabase.from("device_tokens").delete().eq("token", token);
    }
  }));
}

async function nameOf(userId: string): Promise<string> {
  const { data } = await supabase.from("profiles").select("name").eq("id", userId).single();
  return data?.name ?? "Someone";
}

Deno.serve(async (request) => {
  const payload = (await request.json()) as WebhookPayload;
  if (payload.type !== "INSERT") return new Response("ignored", { status: 200 });

  if (payload.table === "messages") {
    const { match_id, sender_id, text } = payload.record as {
      match_id: string; sender_id: string; text: string;
    };
    const { data: match } = await supabase
      .from("matches")
      .select("user_a, user_b")
      .eq("id", match_id)
      .single();
    if (!match) return new Response("no match", { status: 200 });

    const recipient = match.user_a === sender_id ? match.user_b : match.user_a;
    const sender = await nameOf(sender_id);
    await sendToUser(recipient, sender, text, { kind: "message", match_id });
  }

  if (payload.table === "matches") {
    const { id, user_a, user_b } = payload.record as { id: string; user_a: string; user_b: string };
    const [nameA, nameB] = await Promise.all([nameOf(user_a), nameOf(user_b)]);
    await Promise.all([
      sendToUser(user_a, "It's a match!", `You and ${nameB} liked each other.`, { kind: "match", match_id: id }),
      sendToUser(user_b, "It's a match!", `You and ${nameA} liked each other.`, { kind: "match", match_id: id }),
    ]);
  }

  return new Response("ok", { status: 200 });
});
