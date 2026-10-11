-- partymate update 4: party cover photos.
-- Paste into Supabase: SQL Editor > New query > Run. Safe to run more than once.

-- Optional photo shown instead of the emoji. The emoji stays as the fallback.
-- Photos are uploaded to the existing public "avatars" bucket, inside the host's own folder,
-- which the storage rules from update 2 already allow.
alter table public.parties add column if not exists cover_url text;
