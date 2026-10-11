-- Removes everything supabase/seed-demo.sql added.
-- Paste into Supabase: SQL Editor > New query > Run.
-- Your own account, profile, and parties you created yourself are not touched.

-- Demo parties (including the one it created for you to host). Guest lists, likes,
-- matches, and messages at these parties are deleted with them.
delete from public.parties where id::text like 'fa1e0001-%';

-- The fake people. Their profiles and anything else of theirs are deleted with them.
delete from auth.users where id::text like 'fa1e0000-%';
