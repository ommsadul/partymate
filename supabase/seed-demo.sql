-- partymate demo data, for trying the app with realistic content.
-- Paste into Supabase: SQL Editor > New query > Run.
--
-- Adds it for the account that signed in most recently (you, in the simulator):
--   * 24 fake people with photos, bios, and Instagram handles
--   * 1 more party you host (10 going, 3 invited), on top of any you already host
--   * 8 parties hosted by others that you're going to
--   * 3 invitations waiting for your answer
--   * 7 people who already liked you (like them back for an instant match)
--   * 4 matches: one brand new, three with chats (two have unread messages)
--
-- Safe to run more than once: it removes the previous demo data first.
-- To remove it all, run supabase/remove-demo.sql.
-- Fake people use ids starting with fa1e0000-, demo parties fa1e0001-.
-- Profile photos come from randomuser.me; party cover photos from picsum.photos.
--
-- Everything is in one block because the SQL Editor may run separate statements
-- in separate sessions.

do $$
declare
    me uuid;
    me_name text;
    p uuid[];   -- p[n] = fake person n
    pt uuid[];  -- pt[n] = demo party n
    m uuid;

    people jsonb := $j$[
        {"n": 1,  "name": "Maya",     "age": 26, "sex": "women", "ig": "maya.moves",    "bio": "Always the first one on the dance floor."},
        {"n": 2,  "name": "Jordan",   "age": 28, "sex": "men",   "ig": "jordanbeats",   "bio": "Here for the playlist, staying for the snacks."},
        {"n": 3,  "name": "Priya",    "age": 25, "sex": "women", "ig": "priya.bakes",   "bio": "Ask me about my sourdough starter."},
        {"n": 4,  "name": "Leo",      "age": 30, "sex": "men",   "ig": "leo.spins",     "bio": "Amateur DJ, professional hype man."},
        {"n": 5,  "name": "Sofia",    "age": 27, "sex": "women", "ig": "sofiasings",    "bio": "I'll know the words to every song."},
        {"n": 6,  "name": "Marcus",   "age": 29, "sex": "men",   "ig": "marcus.climbs", "bio": "Climbing gyms by day, karaoke by night."},
        {"n": 7,  "name": "Aisha",    "age": 24, "sex": "women", "ig": "aisha.frames",  "bio": "Film photographer. I'll take your picture."},
        {"n": 8,  "name": "Ethan",    "age": 31, "sex": "men",   "ig": "ethanplays",    "bio": "Bringing the board games. You bring the competition."},
        {"n": 9,  "name": "Chloe",    "age": 26, "sex": "women", "ig": "chloemixes",    "bio": "Plant mom and amateur mixologist."},
        {"n": 10, "name": "Diego",    "age": 27, "sex": "men",   "ig": "diego.eats",    "bio": "Taco snob. Fight me."},
        {"n": 11, "name": "Hana",     "age": 25, "sex": "women", "ig": "hana.explores", "bio": "New to the city, say hi!"},
        {"n": 12, "name": "Noah",     "age": 28, "sex": "men",   "ig": "noahruns",      "bio": "Runner, reader, terrible dancer."},
        {"n": 13, "name": "Zoe",      "age": 23, "sex": "women", "ig": "zoeglitter",    "bio": "Glitter is a personality trait."},
        {"n": 14, "name": "Sam",      "age": 29, "sex": "men",   "ig": "sam.rooftop",   "bio": "I host the best rooftop nights."},
        {"n": 15, "name": "Isabella", "age": 27, "sex": "women", "ig": "bella.sips",    "bio": "Wine nerd. Cheese enthusiast."},
        {"n": 16, "name": "Kai",      "age": 26, "sex": "men",   "ig": "kai.waves",     "bio": "Surf, sun, repeat."},
        {"n": 17, "name": "Nina",     "age": 28, "sex": "women", "ig": "nina.spooky",   "bio": "Halloween is my Super Bowl."},
        {"n": 18, "name": "Omar",     "age": 30, "sex": "men",   "ig": "omar.cooks",    "bio": "Cooks for everyone, eats last."},
        {"n": 19, "name": "Lily",     "age": 24, "sex": "women", "ig": "lilystyles",    "bio": "I'll hype your outfit."},
        {"n": 20, "name": "Ryan",     "age": 27, "sex": "men",   "ig": "ryan.and.dog",  "bio": "Mostly here for the dog at every party."},
        {"n": 21, "name": "Ava",      "age": 26, "sex": "women", "ig": "ava.reads",     "bio": "Bookworm who secretly loves techno."},
        {"n": 22, "name": "Theo",     "age": 25, "sex": "men",   "ig": "theo.strums",   "bio": "Guitar in the car, just in case."},
        {"n": 23, "name": "Grace",    "age": 29, "sex": "women", "ig": "gracehosts",    "bio": "Event planner, off the clock."},
        {"n": 24, "name": "Ben",      "age": 31, "sex": "men",   "ig": "ben.grills",    "bio": "Grill master. Bring an appetite."}
    ]$j$;

    -- "host": null means you host it. "guests" and "invited" are fake people's numbers.
    parties jsonb := $j$[
        {"n": 1,  "code": "DEMO01", "host": null, "name": "Birthday Dinner", "emoji": "🎂", "days": 5, "hours": 2,
         "location": "Lucia's Trattoria, 2nd floor", "details": "Dinner first, drinks after. Dress up a little!",
         "cover": null, "status": "going", "guests": [1,2,3,5,6,7,9,11,12,13], "invited": [19,20,22]},
        {"n": 2,  "code": "DEMO02", "host": 14, "name": "Rooftop Sunset Session", "emoji": "🌇", "days": 1, "hours": 1,
         "location": "Sam's rooftop, 88 Park St", "details": "Golden hour, good music, BYOB.",
         "cover": "rooftop", "status": "going", "guests": [1,2,3,4,5,6,7,9,11,13,19,21], "invited": []},
        {"n": 3,  "code": "DEMO03", "host": 4, "name": "Garage Disco", "emoji": "🪩", "days": 3, "hours": 4,
         "location": "Leo's garage (side door)", "details": "The disco ball is up. Wear something shiny.",
         "cover": "disco", "status": "going", "guests": [2,5,9,13,16,19,20,22,24], "invited": []},
        {"n": 4,  "code": "DEMO04", "host": 10, "name": "Taco Tuesday", "emoji": "🌮", "days": 6, "hours": 1,
         "location": "Diego's place", "details": "Build-your-own tacos. I have the salsa covered.",
         "cover": null, "status": "going", "guests": [3,6,11,12,18,21,23], "invited": []},
        {"n": 5,  "code": "DEMO05", "host": 8, "name": "Game Night", "emoji": "🎮", "days": 9, "hours": 3,
         "location": "Ethan's apartment, 4B", "details": "Catan, Codenames, and too much pizza.",
         "cover": null, "status": "going", "guests": [2,7,12,20,21,22], "invited": []},
        {"n": 6,  "code": "DEMO06", "host": 17, "name": "Halloween House Party", "emoji": "🎃", "days": 24, "hours": 4,
         "location": "The house on Elm St", "details": "Costumes required. Best costume wins a prize.",
         "cover": "halloween", "status": "going", "guests": [1,2,3,4,5,6,9,11,13,15,16,19,20,22,24], "invited": []},
        {"n": 7,  "code": "DEMO07", "host": 5, "name": "Karaoke Night", "emoji": "🎤", "days": 12, "hours": 5,
         "location": "Lucky Star Karaoke, Room 3", "details": "Private room until 2am. Duets encouraged.",
         "cover": null, "status": "going", "guests": [1,4,6,7,13,19,22,23], "invited": []},
        {"n": 8,  "code": "DEMO08", "host": 16, "name": "Beach Bonfire", "emoji": "🏖️", "days": 15, "hours": 0,
         "location": "North Beach, by lifeguard tower 6", "details": "Bring a blanket and a hoodie.",
         "cover": "beach", "status": "going", "guests": [3,6,9,11,12,14,18,20,21,24], "invited": []},
        {"n": 9,  "code": "DEMO09", "host": 15, "name": "Wine & Cheese", "emoji": "🥂", "days": 18, "hours": 2,
         "location": "Bella's loft", "details": "Bring a bottle you love.",
         "cover": null, "status": "going", "guests": [1,7,9,11,18,21,23], "invited": []},
        {"n": 10, "code": "DEMO10", "host": 1, "name": "Maya's 25th", "emoji": "🎈", "days": 8, "hours": 3,
         "location": "Neon Room, downtown", "details": "Celebrate with me! Cake at 10.",
         "cover": null, "status": "invited", "guests": [2,3,5,7,9,11,13,15,19,21,23], "invited": []},
        {"n": 11, "code": "DEMO11", "host": 23, "name": "Friendsgiving", "emoji": "🦃", "days": 45, "hours": 0,
         "location": "Grace's house", "details": "Potluck. Sign up for a dish when you get there.",
         "cover": null, "status": "invited", "guests": [3,6,8,10,12,15,18,21,24], "invited": []},
        {"n": 12, "code": "DEMO12", "host": 9, "name": "Pool Party", "emoji": "🏊", "days": 20, "hours": -2,
         "location": "Chloe's building, rooftop pool", "details": "Sunscreen, snacks, good vibes.",
         "cover": "pool", "status": "invited", "guests": [1,5,7,11,13,16,19,22], "invited": []}
    ]$j$;
begin
    p := array(select ('fa1e0000-0000-4000-8000-' || lpad(g::text, 12, '0'))::uuid from generate_series(1, 24) g order by g);
    pt := array(select ('fa1e0001-0000-4000-8000-' || lpad(g::text, 12, '0'))::uuid from generate_series(1, 12) g order by g);

    -- 1. Remove the previous demo data.
    delete from public.parties where id::text like 'fa1e0001-%';
    delete from auth.users where id::text like 'fa1e0000-%';

    -- 2. You: the account that signed in most recently.
    select pr.id, pr.name into me, me_name
    from public.profiles pr
    join auth.users u on u.id = pr.id
    order by u.last_sign_in_at desc nulls last
    limit 1;

    if me is null then
        raise exception 'No account found. Sign in to the app and finish your profile, then run this again.';
    end if;

    -- 3. The fake people.
    insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new, email_change
    )
    select
        '00000000-0000-0000-0000-000000000000', p[x.n], 'authenticated', 'authenticated',
        lower(x.name) || '.' || x.n || '@demo.partymate.app', '', now(),
        '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(),
        '', '', '', ''
    from jsonb_to_recordset(people) as x(n int, name text);

    insert into public.profiles (id, name, age, bio, avatar_url, instagram, photo_urls)
    select
        p[x.n], x.name, x.age, x.bio,
        format('https://randomuser.me/api/portraits/%s/%s.jpg', x.sex, (x.n * 3) % 90 + 1),
        x.ig,
        array[
            format('https://randomuser.me/api/portraits/%s/%s.jpg', x.sex, (x.n * 3) % 90 + 1),
            format('https://randomuser.me/api/portraits/%s/%s.jpg', x.sex, (x.n * 3 + 41) % 90 + 1)
        ]
    from jsonb_to_recordset(people) as x(n int, name text, age int, sex text, ig text, bio text);

    -- 4. Parties. A trigger adds each host as "going".
    insert into public.parties (id, host_id, name, starts_at, location, details, cover_emoji, invite_code)
    select
        pt[d.n], coalesce(p[d.host], me), d.name,
        date_trunc('hour', now()) + make_interval(days => d.days, hours => d.hours),
        d.location, d.details, d.emoji, d.code
    from jsonb_to_recordset(parties) as d(n int, code text, host int, name text, emoji text, days int, hours int, location text, details text);

    -- Cover photos, only if update 4 (party covers) has been run.
    if exists (
        select 1 from information_schema.columns
        where table_schema = 'public' and table_name = 'parties' and column_name = 'cover_url'
    ) then
        execute $q$
            update public.parties pa
            set cover_url = 'https://picsum.photos/seed/partymate-' || d.cover || '/1200/800'
            from jsonb_to_recordset($1) as d(n int, cover text)
            where pa.id = ('fa1e0001-0000-4000-8000-' || lpad(d.n::text, 12, '0'))::uuid
              and d.cover is not null
        $q$ using parties;
    end if;

    -- Your RSVP to parties other people host.
    insert into public.party_members (party_id, user_id, status)
    select pt[d.n], me, d.status
    from jsonb_to_recordset(parties) as d(n int, host int, status text)
    where d.host is not null;

    -- Guest lists.
    insert into public.party_members (party_id, user_id, status)
    select pt[d.n], p[g::int], 'going'
    from jsonb_to_recordset(parties) as d(n int, guests jsonb),
         jsonb_array_elements_text(d.guests) as g
    on conflict (party_id, user_id) do nothing;

    insert into public.party_members (party_id, user_id, status)
    select pt[d.n], p[g::int], 'invited'
    from jsonb_to_recordset(parties) as d(n int, invited jsonb),
         jsonb_array_elements_text(d.invited) as g
    on conflict (party_id, user_id) do nothing;

    -- 5. People who already liked you. Like them back in the app for an instant match.
    insert into public.likes (party_id, from_user, to_user, is_like) values
        (pt[2], p[1],  me, true),
        (pt[2], p[5],  me, true),
        (pt[2], p[11], me, true),
        (pt[3], p[13], me, true),
        (pt[3], p[22], me, true),
        (pt[1], p[2],  me, true),
        (pt[1], p[7],  me, true);

    -- 6. Existing matches: they liked you, then you liked them (a trigger creates the match).
    insert into public.likes (party_id, from_user, to_user, is_like) values
        (pt[2], p[3],  me, true),
        (pt[2], p[6],  me, true),
        (pt[4], p[21], me, true),
        (pt[6], p[19], me, true);

    insert into public.likes (party_id, from_user, to_user, is_like) values
        (pt[2], me, p[3],  true),
        (pt[2], me, p[6],  true),
        (pt[4], me, p[21], true),
        (pt[6], me, p[19], true);

    -- Priya, Rooftop: her last message is unread.
    select id into m from public.matches
    where party_id = pt[2] and user_a = least(me, p[3]) and user_b = greatest(me, p[3]);
    insert into public.messages (match_id, sender_id, text, created_at, read_at) values
        (m, p[3], 'Hey! Are you going to the rooftop thing tomorrow?', now() - interval '3 hours', now() - interval '2 hours 55 minutes'),
        (m, me,   'Yes! Sam''s parties are always good', now() - interval '2 hours 50 minutes', now() - interval '2 hours 48 minutes'),
        (m, p[3], 'Same. I''ll be the one with the polaroid camera 📸', now() - interval '2 hours 45 minutes', now() - interval '2 hours 40 minutes'),
        (m, p[3], 'Want to grab a drink before?', now() - interval '20 minutes', null);
    update public.matches set created_at = now() - interval '3 hours 10 minutes' where id = m;

    -- Marcus, Rooftop: you sent the last message and he read it.
    select id into m from public.matches
    where party_id = pt[2] and user_a = least(me, p[6]) and user_b = greatest(me, p[6]);
    insert into public.messages (match_id, sender_id, text, created_at, read_at) values
        (m, p[6], 'Saw you''re into climbing too?', now() - interval '1 day 2 hours', now() - interval '1 day 1 hour'),
        (m, me,   'Kind of! Total beginner though', now() - interval '1 day 1 hour', now() - interval '1 day'),
        (m, p[6], 'We should go sometime, I''ll show you the ropes 😄', now() - interval '1 day', now() - interval '23 hours'),
        (m, me,   'Deal. See you at the rooftop!', now() - interval '22 hours', now() - interval '21 hours');
    update public.matches set created_at = now() - interval '1 day 3 hours' where id = m;

    -- Lily, Halloween: two unread messages.
    select id into m from public.matches
    where party_id = pt[6] and user_a = least(me, p[19]) and user_b = greatest(me, p[19]);
    insert into public.messages (match_id, sender_id, text, created_at, read_at) values
        (m, p[19], 'Okay what are you going as for Halloween??', now() - interval '2 hours', null),
        (m, p[19], 'I need costume ideas 🎃', now() - interval '1 hour 58 minutes', null);
    update public.matches set created_at = now() - interval '5 hours' where id = m;

    -- Ava, Taco Tuesday: just matched, no messages yet.
    update public.matches set created_at = now() - interval '30 minutes'
    where party_id = pt[4] and user_a = least(me, p[21]) and user_b = greatest(me, p[21]);

    raise notice 'Demo data added for %', me_name;
end;
$$;

-- Shows whose account got the demo data.
select pr.name as "Demo data added for"
from public.profiles pr
join auth.users u on u.id = pr.id
where pr.id::text not like 'fa1e0000-%'
order by u.last_sign_in_at desc nulls last
limit 1;
