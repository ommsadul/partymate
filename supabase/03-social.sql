-- partymate update 3: multiple photos, block/report/unmatch, read receipts,
-- leaving a party removes your matches there, device tokens for push.
-- Paste into Supabase: SQL Editor > New query > Run. Safe to run more than once.

-- ---------------------------------------------------------------------------
-- 1. Multiple profile photos (first one is the main photo)
-- ---------------------------------------------------------------------------

alter table public.profiles add column if not exists photo_urls text[] not null default '{}';

-- ---------------------------------------------------------------------------
-- 2. Blocks and reports
-- ---------------------------------------------------------------------------

create table if not exists public.blocks (
    blocker_id uuid not null references public.profiles (id) on delete cascade,
    blocked_id uuid not null references public.profiles (id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (blocker_id, blocked_id)
);

create table if not exists public.reports (
    id uuid primary key default gen_random_uuid(),
    reporter_id uuid not null references public.profiles (id) on delete cascade,
    reported_id uuid not null references public.profiles (id) on delete cascade,
    party_id uuid references public.parties (id) on delete set null,
    reason text not null,
    details text not null default '',
    created_at timestamptz not null default now()
);

alter table public.blocks enable row level security;
alter table public.reports enable row level security;

drop policy if exists "blocks: read own" on public.blocks;
create policy "blocks: read own" on public.blocks
for select to authenticated
using (blocker_id = auth.uid());

drop policy if exists "blocks: insert own" on public.blocks;
create policy "blocks: insert own" on public.blocks
for insert to authenticated
with check (blocker_id = auth.uid() and blocked_id <> auth.uid());

drop policy if exists "blocks: delete own" on public.blocks;
create policy "blocks: delete own" on public.blocks
for delete to authenticated
using (blocker_id = auth.uid());

-- Reports are write-only for users; you review them in the Supabase dashboard.
drop policy if exists "reports: insert own" on public.reports;
create policy "reports: insert own" on public.reports
for insert to authenticated
with check (reporter_id = auth.uid() and reported_id <> auth.uid());

-- True when either person has blocked the other.
create or replace function public.is_blocked_between(a uuid, b uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
    select exists (
        select 1 from public.blocks
        where (blocker_id = a and blocked_id = b)
           or (blocker_id = b and blocked_id = a)
    );
$$;

-- Blocking someone removes any match and likes between you, at every party.
create or replace function public.handle_block()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    delete from public.matches
    where (user_a = new.blocker_id and user_b = new.blocked_id)
       or (user_a = new.blocked_id and user_b = new.blocker_id);

    delete from public.likes
    where (from_user = new.blocker_id and to_user = new.blocked_id)
       or (from_user = new.blocked_id and to_user = new.blocker_id);

    return new;
end;
$$;

drop trigger if exists blocks_cleanup on public.blocks;
create trigger blocks_cleanup
after insert on public.blocks
for each row execute function public.handle_block();

-- You can't like someone who has blocked you (or whom you've blocked).
drop policy if exists "likes: insert own" on public.likes;
create policy "likes: insert own" on public.likes
for insert to authenticated
with check (
    from_user = auth.uid()
    and public.is_party_member(party_id)
    and not public.is_blocked_between(auth.uid(), to_user)
);

-- The match trigger also respects blocks.
create or replace function public.create_match_on_mutual_like()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if new.is_like
       and not public.is_blocked_between(new.from_user, new.to_user)
       and exists (
           select 1 from public.likes
           where party_id = new.party_id
             and from_user = new.to_user
             and to_user = new.from_user
             and is_like
       )
    then
        insert into public.matches (party_id, user_a, user_b)
        values (
            new.party_id,
            least(new.from_user, new.to_user),
            greatest(new.from_user, new.to_user)
        )
        on conflict (party_id, user_a, user_b) do nothing;
    end if;
    return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Unmatch: either person can delete the match (messages go with it)
-- ---------------------------------------------------------------------------

drop policy if exists "matches: unmatch" on public.matches;
create policy "matches: unmatch" on public.matches
for delete to authenticated
using (auth.uid() in (user_a, user_b));

-- ---------------------------------------------------------------------------
-- 4. Guest list that hides blocked people in both directions
-- ---------------------------------------------------------------------------

create or replace function public.party_guests(p_party uuid)
returns setof public.profiles
language sql
security definer
stable
set search_path = public
as $$
    select p.*
    from public.party_members pm
    join public.profiles p on p.id = pm.user_id
    where pm.party_id = p_party
      and pm.status = 'going'
      and pm.user_id <> auth.uid()
      and public.is_party_member(p_party)
      and not public.is_blocked_between(auth.uid(), pm.user_id)
    order by pm.created_at;
$$;

-- How many people are going to each of the given parties (members only).
create or replace function public.party_going_counts(p_party_ids uuid[])
returns table (party_id uuid, going_count integer)
language sql
stable
set search_path = public
as $$
    select pm.party_id, count(*)::integer
    from public.party_members pm
    where pm.party_id = any (p_party_ids)
      and pm.status = 'going'
    group by pm.party_id;
$$;

-- ---------------------------------------------------------------------------
-- 5. Leaving a party removes your likes and matches from that party
-- ---------------------------------------------------------------------------

create or replace function public.handle_leave_party()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    leaver uuid := coalesce(old.user_id, new.user_id);
    left_party uuid := coalesce(old.party_id, new.party_id);
begin
    if tg_op = 'DELETE' or (old.status = 'going' and new.status <> 'going') then
        delete from public.likes
        where party_id = left_party
          and (from_user = leaver or to_user = leaver);

        delete from public.matches
        where party_id = left_party
          and (user_a = leaver or user_b = leaver);
    end if;
    return coalesce(new, old);
end;
$$;

drop trigger if exists party_members_leave on public.party_members;
create trigger party_members_leave
after update or delete on public.party_members
for each row execute function public.handle_leave_party();

-- ---------------------------------------------------------------------------
-- 6. Read receipts
-- ---------------------------------------------------------------------------

alter table public.messages add column if not exists read_at timestamptz;

-- The recipient can mark a message as read; nobody else can change messages.
drop policy if exists "messages: mark read" on public.messages;
create policy "messages: mark read" on public.messages
for update to authenticated
using (
    sender_id <> auth.uid()
    and exists (
        select 1 from public.matches m
        where m.id = match_id and auth.uid() in (m.user_a, m.user_b)
    )
)
with check (
    sender_id <> auth.uid()
    and exists (
        select 1 from public.matches m
        where m.id = match_id and auth.uid() in (m.user_a, m.user_b)
    )
);

-- ---------------------------------------------------------------------------
-- 7. Device tokens for push notifications
-- ---------------------------------------------------------------------------

create table if not exists public.device_tokens (
    token text primary key,
    user_id uuid not null references public.profiles (id) on delete cascade,
    platform text not null default 'ios',
    updated_at timestamptz not null default now()
);

create index if not exists device_tokens_user_idx on public.device_tokens (user_id);

alter table public.device_tokens enable row level security;

drop policy if exists "device_tokens: manage own" on public.device_tokens;
create policy "device_tokens: manage own" on public.device_tokens
for all to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

-- Realtime also needs to deliver match deletions (unmatch) and message updates (read receipts).
do $$
begin
    alter publication supabase_realtime add table public.matches;
exception
    when duplicate_object then null;
end;
$$;
