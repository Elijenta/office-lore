-- =================================================================
-- OFFICE LORE — DEMO SEED DATA (OPTIONAL — safe to skip entirely)
-- =================================================================
-- This loads the same placeholder content the app used to ship with
-- as hardcoded mock data (a few nicknames, quotes, anecdotes, counters,
-- beers and beer sessions) so you have something to look at immediately.
--
-- Skip this file completely if you'd rather start with a clean, empty
-- app — nothing else depends on it.
--
-- Requires 0001_schema.sql to have been run first, AND the 3 accounts
-- to already exist (Authentication -> Users -> Add user).
--
-- Before running: replace the 3 emails below with whichever real
-- emails you actually used when creating the accounts.
-- =================================================================

do $$
declare
  elien_id uuid;
  nick_id uuid;
  atti_id uuid;

  n1 uuid; n2 uuid; n3 uuid; n4 uuid;
  q1 uuid; q2 uuid; q3 uuid;
  a1 uuid; a2 uuid; a3 uuid;
  c1 uuid; c2 uuid; c3 uuid; c4 uuid;

  b1 uuid; b2 uuid; b3 uuid; b4 uuid;
  s1 uuid; s2 uuid; s3 uuid; s4 uuid;
begin
  -- <<< EDIT THESE 3 EMAILS to match the accounts you actually created >>>
  select id into elien_id from auth.users where email = 'elien@officelore.app';
  select id into nick_id   from auth.users where email = 'nick@officelore.app';
  select id into atti_id   from auth.users where email = 'atti@officelore.app';

  if elien_id is null or nick_id is null or atti_id is null then
    raise exception 'Could not find all 3 accounts. Create elien@officelore.app, nick@officelore.app and atti@officelore.app via Authentication -> Users first (or edit the 3 emails at the top of this DO block to match what you used), then re-run this file.';
  end if;

  -- fill in the profiles (the trigger already created them empty)
  update public.profiles set
    display_name='Elien', first_name='Elien', avatar_emoji='🦉', accent_color='var(--lilac)',
    bio='Houdt de Office Lore-app draaiende en verzamelt alle bewijs.'
    where id = elien_id;
  update public.profiles set
    display_name='Nick', first_name='Nick', business_unit='Engineering', job_title='Backend Developer',
    avatar_emoji='🐨', accent_color='var(--sky)',
    bio='Fixt bugs sneller dan je ze kan reproduceren.'
    where id = nick_id;
  update public.profiles set
    display_name='Atti', first_name='Atti', business_unit='Marketing', job_title='Brand & Growth',
    avatar_emoji='🦄', accent_color='var(--pink)',
    bio='Verzint altijd de gekste actiethema''s en kent iedereen bij naam binnen een week.'
    where id = atti_id;

  -- ---- nicknames ----
  insert into public.nicknames (nickname, person_real_name, business_unit, description, anecdote, status, created_by_user_id, created_at)
    values ('"De Meme Minister"', 'Atti', 'Marketing', 'Ontstaan na een epische meme-thread die Atti zelf startte in de team-chat.', 'Tijdens de laatste town hall gebruikte de CEO deze naam per ongeluk.', 'Actief', nick_id, '2026-07-22')
    returning id into n1;
  insert into public.nickname_events (nickname_id, event_type, xp_value, created_by_user_id, created_at) values
    (n1, 'reused', 1, elien_id, '2026-07-23'),
    (n1, 'used_present', 2, atti_id, '2026-07-26'),
    (n1, 'person_laughs', 3, nick_id, '2026-07-29');
  insert into public.nickname_votes (nickname_id, user_id, vote_type) values
    (n1, elien_id, 'funny'), (n1, nick_id, 'funny'), (n1, atti_id, 'accurate');

  insert into public.nicknames (nickname, person_real_name, business_unit, description, status, created_by_user_id, created_at)
    values ('"Atti die op tafel klopt"', 'Atti', 'Marketing', 'Atti klopt op tafel wanneer die het ergens roerend mee eens is tijdens meetings - inmiddels een herkenningsteken.', 'Actief', elien_id, '2026-08-01')
    returning id into n2;

  insert into public.nicknames (nickname, person_real_name, business_unit, description, anecdote, status, created_by_user_id, created_at)
    values ('"Atti die zichzelf als groot licht gedraagt"', 'Atti', 'Marketing', 'Na een zelfverzekerde speech tijdens de kick-off waarin Atti zichzelf vergeleek met een lichtbaken.', 'Een klant vroeg achteraf of "het licht" ook aan de vergadering zou deelnemen.', 'Actief', atti_id, '2026-08-05')
    returning id into n3;
  insert into public.nickname_events (nickname_id, event_type, xp_value, created_by_user_id, created_at) values
    (n3, 'used_outsider', 5, nick_id, '2026-08-06');
  insert into public.nickname_votes (nickname_id, user_id, vote_type) values
    (n3, elien_id, 'savage'), (n3, nick_id, 'savage');

  insert into public.nicknames (nickname, person_real_name, business_unit, description, anecdote, status, created_by_user_id, created_at)
    values ('"Ctrl+Z Koning"', 'Nick', 'Engineering', 'Nick drukt letterlijk Ctrl+Z als hij een verkeerde beslissing neemt, ook buiten de code.', 'Probeerde ooit een fysieke handdruk ongedaan te maken met Ctrl+Z.', 'Actief', atti_id, '2026-07-24')
    returning id into n4;
  insert into public.nickname_events (nickname_id, event_type, xp_value, created_by_user_id, created_at) values
    (n4, 'self_used', 15, atti_id, '2026-07-28');
  insert into public.nickname_votes (nickname_id, user_id, vote_type) values
    (n4, atti_id, 'funny'), (n4, elien_id, 'accurate'), (n4, nick_id, 'accurate');

  -- ---- quotes ----
  insert into public.quotes (person_real_name, business_unit, quote, context, all_three_bonus_awarded, created_by_user_id, created_at) values
    ('Atti', 'Marketing', '"We doen gewoon iets en kijken wat er gebeurt."', 'Tijdens de sprint planning, toen niemand een duidelijk plan had.', true, elien_id, '2026-07-25')
    returning id into q1;
  insert into public.quote_reactions (quote_id, user_id, reaction_type) values
    (q1, elien_id, 'funny'), (q1, nick_id, 'funny'), (q1, atti_id, 'funny'), (q1, nick_id, 'savage');

  insert into public.quotes (person_real_name, business_unit, quote, context, all_three_bonus_awarded, created_by_user_id, created_at) values
    ('Atti', 'Marketing', '"Als het niet werkt, noemen we het een feature."', '', false, nick_id, '2026-08-03')
    returning id into q2;
  insert into public.quote_reactions (quote_id, user_id, reaction_type) values (q2, elien_id, 'funny');

  insert into public.quotes (person_real_name, business_unit, quote, context, all_three_bonus_awarded, created_by_user_id, created_at) values
    ('Nick', 'Engineering', '"Works on my machine."', 'Antwoord op een bugreport, vlak voor de deploy.', true, nick_id, '2026-08-01')
    returning id into q3;
  insert into public.quote_reactions (quote_id, user_id, reaction_type) values
    (q3, elien_id, 'funny'), (q3, atti_id, 'funny'), (q3, nick_id, 'savage'), (q3, elien_id, 'facepalm');

  -- ---- anecdotes ----
  insert into public.anecdotes (person_real_name, business_unit, title, description, all_three_bonus_awarded, created_by_user_id, created_at) values
    ('Atti', 'Marketing', 'Presentatie in de verkeerde taal', 'Vijf slides ver voor iemand het durfde te zeggen.', true, elien_id, '2026-07-30')
    returning id into a1;
  insert into public.anecdote_reactions (anecdote_id, user_id, reaction_type) values
    (a1, nick_id, 'funny'), (a1, atti_id, 'funny'), (a1, elien_id, 'facepalm');

  insert into public.anecdotes (person_real_name, business_unit, title, description, all_three_bonus_awarded, created_by_user_id, created_at) values
    ('Atti', 'Marketing', 'De actiethema-brainstorm die uit de hand liep', 'Begon met confetti-ideeën en eindigde met een discussie of duiven een geldig kantoordier zijn.', false, atti_id, '2026-08-04')
    returning id into a2;
  insert into public.anecdote_reactions (anecdote_id, user_id, reaction_type) values (a2, elien_id, 'funny');

  insert into public.anecdotes (person_real_name, business_unit, title, description, all_three_bonus_awarded, created_by_user_id, created_at) values
    ('Nick', 'Engineering', 'Deploy op vrijdagnamiddag', 'Wat kan er nu fout gaan, dacht hij nog.', true, nick_id, '2026-08-07')
    returning id into a3;
  insert into public.anecdote_reactions (anecdote_id, user_id, reaction_type) values
    (a3, nick_id, 'funny'), (a3, elien_id, 'savage'), (a3, atti_id, 'facepalm');

  -- ---- counters ----
  insert into public.counters (person_real_name, business_unit, title, description, created_by_user_id, created_at) values
    ('Atti', 'Marketing', 'Atti die op tafel klopt', 'Atti klopt op tafel wanneer die het ergens roerend mee eens is tijdens meetings.', elien_id, '2026-07-20')
    returning id into c1;
  insert into public.counter_events (counter_id, registered_by_user_id, delta, note, created_at) values
    (c1, elien_id, 1, '', '2026-07-21T09:14:00'),
    (c1, nick_id, 1, 'Tijdens de stand-up', '2026-07-21T09:20:00'),
    (c1, atti_id, 1, '', '2026-07-28T11:02:00'),
    (c1, elien_id, 1, '', '2026-08-04T14:45:00'),
    (c1, elien_id, 1, 'Twee keer in dezelfde meeting', '2026-08-11T10:00:00'),
    (c1, elien_id, 1, '', '2026-08-11T10:03:00'),
    (c1, nick_id, 1, '', '2026-08-12T08:30:00');

  insert into public.counters (person_real_name, business_unit, title, description, created_by_user_id, created_at) values
    ('Atti', 'Marketing', 'Atti die zichzelf als groot licht gedraagt', 'Wanneer Atti zichzelf weer eens vergelijkt met een lichtbaken tijdens een speech of pitch.', atti_id, '2026-08-01')
    returning id into c2;
  insert into public.counter_events (counter_id, registered_by_user_id, delta, note, created_at) values
    (c2, nick_id, 1, '', '2026-08-02T16:00:00'),
    (c2, atti_id, 1, 'Kick-off speech', '2026-08-06T13:30:00'),
    (c2, nick_id, 1, '', '2026-08-10T09:00:00');

  insert into public.counters (person_real_name, business_unit, title, description, created_by_user_id, created_at) values
    ('Atti', 'Marketing', 'Keer "we pivoten" gezegd', 'Elke keer dat Atti een nieuw plan verkoopt als "geen koerswijziging, gewoon een pivot".', elien_id, '2026-07-15')
    returning id into c3;
  insert into public.counter_events (counter_id, registered_by_user_id, delta, note, created_at) values
    (c3, nick_id, 1, '', '2026-07-16T10:00:00'),
    (c3, elien_id, 1, '', '2026-07-18T15:20:00'),
    (c3, atti_id, 1, 'Tijdens de OKR-review', '2026-07-22T09:45:00'),
    (c3, elien_id, 1, '', '2026-07-25T11:00:00'),
    (c3, nick_id, 1, '', '2026-07-30T14:10:00'),
    (c3, elien_id, 1, '', '2026-08-03T16:40:00'),
    (c3, atti_id, 1, '', '2026-08-06T10:30:00'),
    (c3, elien_id, 1, '', '2026-08-09T13:00:00');

  insert into public.counters (person_real_name, business_unit, title, description, created_by_user_id, created_at) values
    ('Nick', 'Engineering', 'Keer prod gecrasht', 'Elke keer dat een deploy van Nick production platlegt.', nick_id, '2026-07-22')
    returning id into c4;
  insert into public.counter_events (counter_id, registered_by_user_id, delta, note, created_at) values
    (c4, nick_id, 1, 'Vrijdagmiddag deploy', '2026-07-28T17:05:00'),
    (c4, atti_id, 1, '', '2026-08-07T18:20:00');

  -- ---- beers ----
  insert into public.beers (name, brewery, beer_style, alcohol_percentage, country, created_by_user_id, created_at) values
    ('Tripel Karmeliet', 'Bosteels', 'Tripel', 8.4, 'België', elien_id, '2026-07-10') returning id into b1;
  insert into public.beers (name, brewery, beer_style, alcohol_percentage, country, created_by_user_id, created_at) values
    ('Duvel', 'Duvel Moortgat', 'Belgian Strong Golden Ale', 8.5, 'België', nick_id, '2026-07-10') returning id into b2;
  insert into public.beers (name, brewery, beer_style, alcohol_percentage, country, created_by_user_id, created_at) values
    ('La Chouffe', 'Brasserie d''Achouffe', 'Blond', 8.0, 'België', atti_id, '2026-07-15') returning id into b3;
  insert into public.beers (name, brewery, beer_style, alcohol_percentage, country, created_by_user_id, created_at) values
    ('Westmalle Tripel', 'Brouwerij der Trappisten van Westmalle', 'Trappist Tripel', 9.5, 'België', elien_id, '2026-08-01') returning id into b4;

  -- ---- sessie 1 ----
  insert into public.beer_sessions (session_date, location, created_by_user_id, created_at) values
    ('2026-07-12', 'Kantoor terras', elien_id, '2026-07-12') returning id into s1;
  insert into public.beer_session_participants (session_id, user_id) values (s1, elien_id), (s1, nick_id), (s1, atti_id);
  insert into public.beer_ratings (beer_id, session_id, user_id, rating, review) values
    (b1, s1, elien_id, 8, 'Fruitig en romig'), (b1, s1, nick_id, 7, ''), (b1, s1, atti_id, 9, 'Favoriet!'),
    (b2, s1, elien_id, 6, 'Sterk'), (b2, s1, nick_id, 8, ''), (b2, s1, atti_id, 7, '');
  insert into public.beer_consumption (beer_id, session_id, user_id, quantity) values
    (b1, s1, elien_id, 1), (b1, s1, nick_id, 1), (b1, s1, atti_id, 2),
    (b2, s1, elien_id, 1), (b2, s1, nick_id, 1), (b2, s1, atti_id, 1);
  insert into public.perfect_pours (session_id, given_by_user_id, received_by_user_id) values
    (s1, elien_id, atti_id), (s1, nick_id, atti_id), (s1, atti_id, elien_id);

  -- ---- sessie 2 ----
  insert into public.beer_sessions (session_date, location, created_by_user_id, created_at) values
    ('2026-07-26', 'Vrijdagborrel', nick_id, '2026-07-26') returning id into s2;
  insert into public.beer_session_participants (session_id, user_id) values (s2, elien_id), (s2, nick_id);
  insert into public.beer_ratings (beer_id, session_id, user_id, rating, review) values
    (b2, s2, elien_id, 7, 'Nog steeds goed'), (b2, s2, nick_id, 8, ''),
    (b3, s2, elien_id, 9, 'Beste van de avond'), (b3, s2, nick_id, 8, '');
  insert into public.beer_consumption (beer_id, session_id, user_id, quantity) values
    (b2, s2, elien_id, 2), (b2, s2, nick_id, 1),
    (b3, s2, elien_id, 1), (b3, s2, nick_id, 1);
  insert into public.perfect_pours (session_id, given_by_user_id, received_by_user_id) values
    (s2, elien_id, nick_id), (s2, nick_id, elien_id);

  -- ---- sessie 3 ----
  insert into public.beer_sessions (session_date, location, created_by_user_id, created_at) values
    ('2026-08-09', 'Kantoor terras', atti_id, '2026-08-09') returning id into s3;
  insert into public.beer_session_participants (session_id, user_id) values (s3, elien_id), (s3, nick_id), (s3, atti_id);
  insert into public.beer_ratings (beer_id, session_id, user_id, rating, review) values
    (b1, s3, elien_id, 8, ''), (b1, s3, atti_id, 9, ''),
    (b4, s3, elien_id, 7, 'Pittig'), (b4, s3, nick_id, 9, 'Topbier'), (b4, s3, atti_id, 8, '');
  insert into public.beer_consumption (beer_id, session_id, user_id, quantity) values
    (b1, s3, elien_id, 1), (b1, s3, atti_id, 1),
    (b4, s3, elien_id, 1), (b4, s3, nick_id, 1), (b4, s3, atti_id, 2);
  insert into public.perfect_pours (session_id, given_by_user_id, received_by_user_id) values
    (s3, elien_id, nick_id), (s3, atti_id, nick_id);

  -- ---- sessie 4 ----
  insert into public.beer_sessions (session_date, location, created_by_user_id, created_at) values
    ('2026-08-11', 'Weekend BBQ', elien_id, '2026-08-11') returning id into s4;
  insert into public.beer_session_participants (session_id, user_id) values (s4, elien_id), (s4, nick_id), (s4, atti_id);
  insert into public.beer_ratings (beer_id, session_id, user_id, rating, review) values
    (b2, s4, elien_id, 6, 'Ik heb er nog een paar staan liggen'), (b2, s4, nick_id, 8, ''), (b2, s4, atti_id, 7, '');
  insert into public.beer_consumption (beer_id, session_id, user_id, quantity) values
    (b2, s4, elien_id, 11), (b2, s4, nick_id, 1), (b2, s4, atti_id, 2);
  insert into public.perfect_pours (session_id, given_by_user_id, received_by_user_id) values
    (s4, nick_id, atti_id);

  raise notice 'Demo seed data succesvol toegevoegd.';
end $$;
