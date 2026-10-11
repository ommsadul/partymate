-- partymate database schema
-- Paste this whole file into the Supabase dashboard: SQL Editor > New query > Run.
-- It is safe to run more than once.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------

-- One row per signed-in user. Created by the app after first sign-in.
create table if not exists public.profiles (
    id uuid primary key references auth.users (id) on delete cascade,
    name text not null,
    age integer,
    bio text not null default '',
    avatar_emoji text not null default '🙂',
    created_at timestamptz not null default now()
);

-- Short, human-friendly invite codes like "K7M2PQ".
create or replace function public.generate_invite_code()
returns text
language sql
volatile
as $$
    select string_agg(
        substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', (floor(random() * 32))::int + 1, 1),
        ''
    )
    from generate_series(1, 6);
$$;

create table if not exists public.parties (
    id uuid primary key default gen_random_uuid(),
    host_id uuid not null references public.profiles (id) on delete cascade,
    name text not null,
    starts_at timestamptz not null,
    location text not null default '',
    details text not null default '',
    cover_emoji text not null default '🎉',
    invite_code text not null unique default public.generate_invite_code(),
    created_at timestamptz not null default now()
);

-- Who is connected to which party, and their RSVP.
create table if not exists public.party_members (
    party_id uuid not null references public.parties (id) on delete cascade,
    user_id uuid not null references public.profiles (id) on delete cascade,
    status text not null check (status in ('invited', 'going', 'declined')),
    created_at timestamptz not null default now(),
    primary key (party_id, user_id)
);

-- A like (is_like = true) or a pass (is_like = false), per party.
create table if not exists public.likes (
    party_id uuid not null references public.parties (id) on delete cascade,
    from_user uuid not null references public.profiles (id) on delete cascade,
    to_user uuid not null references public.profiles (id) on delete cascade,
    is_like boolean not null,
    created_at timestamptz not null default now(),
    primary key (party_id, from_user, to_user)
);

-- Created automatically when two people like each other at the same party.
-- user_a is always the smaller uuid so each pair appears only once.
create table if not exists public.matches (
    id uuid primary key default gen_random_uuid(),
    party_id uuid not null references public.parties (id) on delete cascade,
    user_a uuid not null references public.profiles (id) on delete cascade,
    user_b uuid not null references public.profiles (id) on delete cascade,
    created_at timestamptz not null default now(),
    unique (party_id, user_a, user_b)
);

create table if not exists public.messages (
    id uuid primary key default gen_random_uuid(),
    match_id uuid not null references public.matches (id) on delete cascade,
    sender_id uuid not null references public.profiles (id) on delete cascade,
    text text not null,
    created_at timestamptz not null default now()
);

create index if not exists messages_match_created_idx on public.messages (match_id, created_at);
create index if not exists party_members_user_idx on public.party_members (user_id);

-- ---------------------------------------------------------------------------
-- 2. Helper functions (security definer so policies can use them without
--    running into their own row-level-security rules)
-- ---------------------------------------------------------------------------

create or replace function public.is_party_member(p_party uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
    select exists (
        select 1 from public.party_members
        where party_id = p_party and user_id = auth.uid()
    );
$$;

create or replace function public.is_party_host(p_party uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
    select exists (
        select 1 from public.parties
        where id = p_party and host_id = auth.uid()
    );
$$;

-- True when the current user and `other` are both connected to at least one same party.
create or replace function public.shares_party_with(other uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
    select exists (
        select 1
        from public.party_members a
        join public.party_members b on a.party_id = b.party_id
        where a.user_id = auth.uid() and b.user_id = other
    );
$$;

-- Called by the app when someone opens an invite link or types a code.
-- Adds them to the party as "invited" and returns the party id.
create or replace function public.join_party(code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    found_party uuid;
begin
    if auth.uid() is null then
        raise exception 'You need to be signed in to join a party.';
    end if;

    select id into found_party
    from public.parties
    where invite_code = upper(trim(code));

    if found_party is null then
        raise exception 'No party found for that invite code.';
    end if;

    insert into public.party_members (party_id, user_id, status)
    values (found_party, auth.uid(), 'invited')
    on conflict (party_id, user_id) do nothing;

    return found_party;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Triggers
-- ---------------------------------------------------------------------------

-- The host is automatically "going" to their own party.
create or replace function public.add_host_as_member()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    insert into public.party_members (party_id, user_id, status)
    values (new.id, new.host_id, 'going')
    on conflict (party_id, user_id) do nothing;
    return new;
end;
$$;

drop trigger if exists parties_add_host on public.parties;
create trigger parties_add_host
after insert on public.parties
for each row execute function public.add_host_as_member();

-- When a like is saved, check whether the other person already liked back.
create or replace function public.create_match_on_mutual_like()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if new.is_like and exists (
        select 1 from public.likes
        where party_id = new.party_id
          and from_user = new.to_user
          and to_user = new.from_user
          and is_like
    ) then
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

drop trigger if exists likes_create_match on public.likes;
create trigger likes_create_match
after insert or update on public.likes
for each row execute function public.create_match_on_mutual_like();

-- ---------------------------------------------------------------------------
-- 4. Row-level security: who can see and change what
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.parties enable row level security;
alter table public.party_members enable row level security;
alter table public.likes enable row level security;
alter table public.matches enable row level security;
alter table public.messages enable row level security;

-- profiles: you can see yourself and anyone who shares a party with you.
drop policy if exists "profiles: read own or shared" on public.profiles;
create policy "profiles: read own or shared" on public.profiles
for select to authenticated
using (id = auth.uid() or public.shares_party_with(id));

drop policy if exists "profiles: insert own" on public.profiles;
create policy "profiles: insert own" on public.profiles
for insert to authenticated
with check (id = auth.uid());

drop policy if exists "profiles: update own" on public.profiles;
create policy "profiles: update own" on public.profiles
for update to authenticated
using (id = auth.uid())
with check (id = auth.uid());

-- parties: only visible to members and the host. No feed, no search.
drop policy if exists "parties: read if member" on public.parties;
create policy "parties: read if member" on public.parties
for select to authenticated
using (host_id = auth.uid() or public.is_party_member(id));

drop policy if exists "parties: host creates" on public.parties;
create policy "parties: host creates" on public.parties
for insert to authenticated
with check (host_id = auth.uid());

drop policy if exists "parties: host updates" on public.parties;
create policy "parties: host updates" on public.parties
for update to authenticated
using (host_id = auth.uid())
with check (host_id = auth.uid());

drop policy if exists "parties: host deletes" on public.parties;
create policy "parties: host deletes" on public.parties
for delete to authenticated
using (host_id = auth.uid());

-- party_members: members can see the guest list; you can change only your own RSVP.
drop policy if exists "members: read if member" on public.party_members;
create policy "members: read if member" on public.party_members
for select to authenticated
using (public.is_party_member(party_id));

drop policy if exists "members: host invites" on public.party_members;
create policy "members: host invites" on public.party_members
for insert to authenticated
with check (public.is_party_host(party_id));

drop policy if exists "members: update own rsvp" on public.party_members;
create policy "members: update own rsvp" on public.party_members
for update to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop policy if exists "members: leave or host removes" on public.party_members;
create policy "members: leave or host removes" on public.party_members
for delete to authenticated
using (user_id = auth.uid() or public.is_party_host(party_id));

-- likes: you only ever see your own likes. Nobody can see who liked them.
drop policy if exists "likes: read own" on public.likes;
create policy "likes: read own" on public.likes
for select to authenticated
using (from_user = auth.uid());

drop policy if exists "likes: insert own" on public.likes;
create policy "likes: insert own" on public.likes
for insert to authenticated
with check (from_user = auth.uid() and public.is_party_member(party_id));

drop policy if exists "likes: update own" on public.likes;
create policy "likes: update own" on public.likes
for update to authenticated
using (from_user = auth.uid())
with check (from_user = auth.uid());

-- matches: visible to the two people in it. Only the trigger creates them.
drop policy if exists "matches: read own" on public.matches;
create policy "matches: read own" on public.matches
for select to authenticated
using (auth.uid() in (user_a, user_b));

-- messages: readable and writable only by the two matched people.
drop policy if exists "messages: read if in match" on public.messages;
create policy "messages: read if in match" on public.messages
for select to authenticated
using (
    exists (
        select 1 from public.matches m
        where m.id = match_id and auth.uid() in (m.user_a, m.user_b)
    )
);

drop policy if exists "messages: send if in match" on public.messages;
create policy "messages: send if in match" on public.messages
for insert to authenticated
with check (
    sender_id = auth.uid()
    and exists (
        select 1 from public.matches m
        where m.id = match_id and auth.uid() in (m.user_a, m.user_b)
    )
);

-- ---------------------------------------------------------------------------
-- 5. Realtime: let the app hear about new messages instantly
-- ---------------------------------------------------------------------------

do $$
begin
    alter publication supabase_realtime add table public.messages;
exception
    when duplicate_object then null;
end;
$$;
