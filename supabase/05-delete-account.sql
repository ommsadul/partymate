-- partymate update 5: let people delete their own account (required by the App Store).
-- Paste into Supabase: SQL Editor > New query > Run. Safe to run more than once.

-- Deletes the signed-in user. Their profile, the parties they host, their RSVPs, likes,
-- matches, and messages are removed by the existing "on delete cascade" rules.
-- The app deletes their photos from storage first (storage can't be cleared from SQL).
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
    if auth.uid() is null then
        raise exception 'You need to be signed in to delete your account.';
    end if;

    delete from auth.users where id = auth.uid();
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
