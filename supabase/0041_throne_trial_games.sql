-- =================================================================
-- OFFICE LORE — THRONE TRIALS: THE FIRST REAL, AUTO-JUDGED GAMES
-- =================================================================
-- 0038 shipped placeholder Trials (roll / one numeric guess / judge). This
-- adds a generic QUIZ ENGINE and ten real games on top of it:
--
--   🍺 PINT     Beer Trivia · Higher or Lower · Guess the Beer
--   📜 LORE     Who Said It? · Nickname Knowledge · Office Lore Quiz
--   🧠 WISDOM   Office Lore Quiz (wisdom edition) · Closest Wins · Know Thy Enemy
--   ⚡ REFLEX   Rapid Fire (60s timer) · Sudden Death
--
-- HOW IT STAYS GENERIC
--   A game is ONE ROW in throne_trial_catalog. Its public_config says:
--     engine/resolution : quiz | timed | streak
--     templates         : which question templates feed it  (_tq_<name>)
--     count, options, duration_s, scoring, fallback, short, final_boost
--   A question template is one SQL function  _tq_<name>(chal, def, n_options)
--   returning rows of throne_question_t. New game from existing templates =
--   one INSERT. New kind of question = one new _tq_ function + its name in
--   a catalog row. New kind of mechanic = a new resolution + one client
--   renderer. The Throne Challenge itself never changes.
--
-- RESOLUTIONS (all auto-judged, nothing needs a human)
--   quiz    fixed list of questions, untimed. scoring:
--             'correct' more right answers wins            (tie: faster)
--             'error'   smaller total relative error wins   (Closest Wins)
--   timed   Rapid Fire. Server clock: the run is open duration_s seconds
--           from the first call to start_throne_run(). score = right - wrong.
--   streak  Sudden Death. A run ends at the first wrong answer; the longer
--           streak wins (tie: faster). Equivalent to "play until one is
--           wrong while the other is right", but works asynchronously.
--
-- FAIRNESS
--   * Questions are generated ONCE, when the Trial starts, and stored per
--     player (throne_trial_questions). Both players get the SAME questions in
--     the SAME order with the SAME option order -- except Know Thy Enemy,
--     where each player gets the MIRROR question about their opponent from
--     the same template (same difficulty, same position).
--   * Refresh / realtime / reconnect never generate anything new: the client
--     asks get_throne_run() and gets the stored questions back.
--   * The answer key never leaves the database: throne_trial_questions has
--     RLS and NO client policy; the RPCs return prompt/facts/options only.
--     Correctness is decided server-side per answer; the right answer is
--     revealed only AFTER that player answered that question.
--   * Own data first (beers, ratings, sessions, nicknames, quotes,
--     anecdotes, poems, battles -- all Office Lore tables, workspace-scoped
--     like the rest). When there is too little, the game is topped up from
--     throne_builtin_trivia (general beer / general knowledge).
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0040.
-- =================================================================

-- =================================================================
-- SECTION 1 — schema
-- =================================================================
do $$
declare
  v_constraint_name text;
begin
  select conname into v_constraint_name
  from pg_constraint
  where conrelid = 'public.throne_trial_catalog'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) like '%resolution%';
  if v_constraint_name is not null then
    execute format('alter table public.throne_trial_catalog drop constraint %I', v_constraint_name);
  end if;
end $$;

alter table public.throne_trial_catalog add constraint throne_trial_catalog_resolution_check
  check (resolution in ('roll', 'answer', 'judge', 'quiz', 'timed', 'streak'));

do $$
begin
  if not exists (select 1 from pg_type where typname = 'throne_question_t' and typnamespace = 'public'::regnamespace) then
    create type public.throne_question_t as (
      grp text,            -- question identity; a mirrored (per-player) pair shares one grp
      for_user_id uuid,    -- null = both players get this exact question
      kind text,           -- 'mc' (multiple choice) | 'numeric'
      tag text,            -- template tag, used for variety when picking
      prompt text,
      facts jsonb,         -- display extras (layout hints, quote text ...) -- never the answer
      options jsonb,       -- [{id,label}] for mc
      answer jsonb         -- {"id":"b"} or {"value":12}  -- PRIVATE
    );
  end if;
end $$;

-- built-in fallback trivia (used only to top up when own data is too thin)
create table if not exists public.throne_builtin_trivia (
  id serial primary key,
  category text not null check (category in ('beer', 'general')),
  prompt text not null unique,
  correct text not null,
  wrongs text[] not null,
  short boolean not null default true
);
alter table public.throne_builtin_trivia enable row level security; -- deliberately NO policy

-- the questions of a Trial, one copy per player (PRIVATE: holds the answers)
create table if not exists public.throne_trial_questions (
  trial_id uuid not null references public.throne_challenge_trials(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  seq int not null,
  kind text not null,
  tag text,
  prompt text not null,
  facts jsonb,
  options jsonb,
  answer jsonb not null,
  primary key (trial_id, user_id, seq)
);
alter table public.throne_trial_questions enable row level security; -- deliberately NO policy

-- one run per player per Trial
create table if not exists public.throne_trial_runs (
  trial_id uuid not null references public.throne_challenge_trials(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  started_at timestamptz not null default clock_timestamp(),
  last_at timestamptz,
  finished_at timestamptz,
  ended_by text check (ended_by in ('complete', 'wrong', 'time', 'deadline')),
  answered int not null default 0,
  correct int not null default 0,
  wrong int not null default 0,
  total_ms bigint not null default 0,
  err_sum numeric not null default 0,
  primary key (trial_id, user_id)
);
alter table public.throne_trial_runs enable row level security; -- deliberately NO policy

-- every answer given (audit + idempotency: a question can be answered once)
create table if not exists public.throne_trial_answers (
  trial_id uuid not null references public.throne_challenge_trials(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  seq int not null,
  choice jsonb not null,
  correct boolean not null,
  err numeric not null default 0,
  ms int not null default 0,
  answered_at timestamptz not null default clock_timestamp(),
  primary key (trial_id, user_id, seq)
);
alter table public.throne_trial_answers enable row level security; -- deliberately NO policy

-- built-in trivia seed
insert into public.throne_builtin_trivia (category, prompt, correct, wrongs) values
  ('beer', 'Which grain is the main ingredient of a classic Weissbier?', 'Wheat', array['Barley', 'Rye', 'Rice']),
  ('beer', 'Which ingredient gives beer most of its bitterness?', 'Hops', array['Malt', 'Yeast', 'Water']),
  ('beer', 'Which microorganism turns the sugars in wort into alcohol?', 'Yeast', array['Hops', 'Barley', 'Water']),
  ('beer', 'The Pilsner style was born in which Czech city?', 'Plzeň', array['Prague', 'Brno', 'Ostrava']),
  ('beer', 'In which city is Guinness brewed?', 'Dublin', array['Cork', 'Belfast', 'Galway']),
  ('beer', 'What does IPA stand for?', 'India Pale Ale', array['Imperial Pale Ale', 'International Pale Ale', 'Irish Pale Ale']),
  ('beer', 'Which Belgian beer style is fermented spontaneously with wild yeast?', 'Lambic', array['Dubbel', 'Tripel', 'Pils']),
  ('beer', 'Which Belgian style is typically strong and golden?', 'Tripel', array['Stout', 'Witbier', 'Porter']),
  ('beer', 'Which German city is the home of Kölsch?', 'Cologne', array['Munich', 'Berlin', 'Hamburg']),
  ('beer', 'In which city is the Oktoberfest held?', 'Munich', array['Berlin', 'Cologne', 'Vienna']),
  ('beer', 'What gives stout its dark colour?', 'Roasted malt', array['Dark hops', 'Food colouring', 'Smoked water']),
  ('beer', 'The sugary liquid before fermentation is called…', 'Wort', array['Krausen', 'Lees', 'Sparge']),
  ('beer', 'What does the Flemish word “Duvel” mean in English?', 'Devil', array['Duke', 'Dragon', 'Dwarf']),
  ('beer', 'Which animal features in the legend of Orval?', 'A trout', array['A swan', 'An eagle', 'A lion']),
  ('beer', 'Which glass shape is traditional for Belgian Trappist beers?', 'A chalice', array['A shot glass', 'A flat saucer', 'A test tube']),
  ('beer', 'In which country is the Trappist beer Westmalle brewed?', 'Belgium', array['The Netherlands', 'Germany', 'France']),
  ('beer', 'Which of these was NOT part of the original 1516 Reinheitsgebot?', 'Sugar', array['Water', 'Barley', 'Hops']),
  ('beer', 'Heineken comes from which country?', 'The Netherlands', array['Belgium', 'Germany', 'Denmark']),
  ('beer', 'Carlsberg comes from which country?', 'Denmark', array['Sweden', 'Norway', 'Germany']),
  ('beer', 'Corona comes from which country?', 'Mexico', array['Spain', 'Brazil', 'Colombia']),
  ('beer', 'Paulaner comes from which country?', 'Germany', array['Austria', 'Belgium', 'Switzerland']),
  ('beer', 'Peroni comes from which country?', 'Italy', array['Spain', 'France', 'Greece']),
  ('beer', 'What is the foam on top of a beer called?', 'The head', array['The cap', 'The lid', 'The veil']),
  ('beer', 'Which has the higher alcohol content: Duvel or Jupiler?', 'Duvel', array['Jupiler']),
  ('beer', 'Which has the higher alcohol content: Westmalle Tripel or Leffe Blonde?', 'Westmalle Tripel', array['Leffe Blonde']),
  ('beer', 'Which has the higher alcohol content: Chimay Blue or Orval?', 'Chimay Blue', array['Orval']),
  ('beer', 'Which has the higher alcohol content: Westvleteren 12 or Guinness Draught?', 'Westvleteren 12', array['Guinness Draught']),
  ('beer', 'Which has the higher alcohol content: Kwak or Hoegaarden?', 'Kwak', array['Hoegaarden']),
  ('beer', 'Which of these is a Trappist beer?', 'Chimay', array['Duvel', 'Leffe', 'Jupiler']),
  ('beer', 'Which of these is NOT a Trappist beer?', 'Leffe', array['Orval', 'Rochefort', 'Westmalle']),
  ('general', 'In which year was the Eiffel Tower completed?', '1889', array['1869', '1901', '1925']),
  ('general', 'How many bones does an adult human have?', '206', array['186', '226', '256']),
  ('general', 'What is the capital of Australia?', 'Canberra', array['Sydney', 'Melbourne', 'Perth']),
  ('general', 'Which planet is the largest in our solar system?', 'Jupiter', array['Saturn', 'Neptune', 'Earth']),
  ('general', 'What is the chemical symbol for gold?', 'Au', array['Ag', 'Gd', 'Go']),
  ('general', 'How many strings does a standard violin have?', '4', array['5', '6', '3']),
  ('general', 'Which ocean is the largest?', 'Pacific', array['Atlantic', 'Indian', 'Arctic']),
  ('general', 'What is the capital of Belgium?', 'Brussels', array['Antwerp', 'Ghent', 'Bruges']),
  ('general', 'Which Belgian city is famous for its diamond trade?', 'Antwerp', array['Ghent', 'Leuven', 'Liège']),
  ('general', 'How many players of one team are on the pitch in football?', '11', array['10', '12', '9']),
  ('general', 'What colour do you get by mixing blue and yellow?', 'Green', array['Purple', 'Orange', 'Brown']),
  ('general', 'Who painted the Mona Lisa?', 'Leonardo da Vinci', array['Michelangelo', 'Raphael', 'Rembrandt'])
on conflict (prompt) do nothing;

-- =================================================================
-- SECTION 2 — small helpers
-- =================================================================
-- builds {options:[{id,label}], answer:{id}} with the options shuffled (or
-- numerically sorted). null when there is no usable wrong answer.
create or replace function public._throne_mc(p_correct text, p_wrongs text[], p_n int default 4, p_sort boolean default false)
returns jsonb as $$
declare
  v_w text[];
  v_all text[];
  v_ids text[] := array['a', 'b', 'c', 'd', 'e'];
  v_opts jsonb := '[]'::jsonb;
  v_ans text;
  i int;
begin
  select coalesce(array_agg(w), '{}') into v_w from (
    select w from (
      select distinct w from unnest(p_wrongs) w
      where w is not null and btrim(w) <> '' and lower(w) <> lower(p_correct)
    ) d order by random() limit greatest(least(p_n, 5) - 1, 1)
  ) s;
  if cardinality(v_w) = 0 then
    return null;
  end if;
  if p_sort then
    select array_agg(l order by l::numeric) into v_all from unnest(array[p_correct] || v_w) l;
  else
    select array_agg(l order by random()) into v_all from unnest(array[p_correct] || v_w) l;
  end if;
  for i in 1..cardinality(v_all) loop
    v_opts := v_opts || jsonb_build_object('id', v_ids[i], 'label', v_all[i]);
    if v_all[i] = p_correct then v_ans := v_ids[i]; end if;
  end loop;
  return jsonb_build_object('options', v_opts, 'answer', jsonb_build_object('id', v_ans));
end;
$$ language plpgsql volatile;

-- multiple-choice around a count: nearby plausible numbers, sorted
create or replace function public._throne_num_mc(p_correct numeric, p_n int default 4)
returns jsonb as $$
declare
  v_c bigint := round(p_correct);
  v_step bigint := greatest(1, round(abs(round(p_correct)) * 0.2));
  v_w text[] := '{}';
  k int;
  cand bigint;
begin
  for k in 1..4 loop
    foreach cand in array array[v_c + k * v_step, v_c - k * v_step] loop
      if cand >= 0 then v_w := v_w || cand::text; end if;
    end loop;
  end loop;
  return public._throne_mc(v_c::text, v_w[1:(greatest(p_n, 2) - 1) * 2], p_n, true);
end;
$$ language plpgsql volatile;

create or replace function public._tq_row(p_grp text, p_user uuid, p_kind text, p_tag text, p_prompt text, p_facts jsonb, p_m jsonb)
returns public.throne_question_t as $$
  select row(coalesce(p_grp, md5(random()::text || clock_timestamp()::text || p_tag)), p_user, p_kind, p_tag, p_prompt, p_facts, p_m->'options', p_m->'answer')::public.throne_question_t;
$$ language sql volatile;

create or replace function public._tq_num_row(p_tag text, p_prompt text, p_value numeric, p_unit text)
returns public.throne_question_t as $$
  select row(md5(random()::text || clock_timestamp()::text || p_tag), null, 'numeric', p_tag, p_prompt,
             jsonb_build_object('unit', p_unit), null, jsonb_build_object('value', p_value))::public.throne_question_t;
$$ language sql volatile;

create or replace function public._throne_clip(p_text text, p_len int)
returns text as $$
  select case when length(btrim(p_text)) > p_len then left(btrim(p_text), p_len - 1) || '…' else btrim(p_text) end;
$$ language sql immutable;

-- every distinct person the Lore tables talk about
create or replace function public._throne_person_pool()
returns text[] as $$
  select coalesce(array_agg(distinct p), '{}') from (
    select btrim(person_real_name) as p from public.nicknames
    union select btrim(person_real_name) from public.quotes
    union select btrim(person_real_name) from public.anecdotes
  ) s where p <> '';
$$ language sql stable security definer set search_path = public;

-- other people, excluding anyone sharing the correct person's first name
-- ("Matthias" vs "Matthias Gils" must never both appear as options)
create or replace function public._throne_other_people(p_correct text)
returns text[] as $$
  select coalesce(array_agg(x), '{}') from unnest(public._throne_person_pool()) x
  where lower(split_part(btrim(x), ' ', 1)) <> lower(split_part(btrim(p_correct), ' ', 1));
$$ language sql stable security definer set search_path = public;

create or replace function public._throne_mentions(p_text text, p_name text)
returns boolean as $$
  select length(split_part(btrim(p_name), ' ', 1)) >= 3
     and position(lower(split_part(btrim(p_name), ' ', 1)) in lower(coalesce(p_text, ''))) > 0;
$$ language sql immutable;

create or replace function public._throne_member_names()
returns text[] as $$
  select coalesce(array_agg(p.display_name order by p.display_name), '{}')
  from public.profiles p
  join public.app_memberships m on m.user_id = p.id and m.app_id = 'officelore' and m.is_active = true;
$$ language sql stable security definer set search_path = public;

-- =================================================================
-- SECTION 3 — question templates  (_tq_<name>(chal, def, n_options))
-- =================================================================

-- ---------- 🍺 beer templates ----------
create or replace function public._tq_beer_style(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
  v_styles text[];
begin
  select array_agg(distinct initcap(lower(btrim(beer_style)))) into v_styles
    from public.beers where nullif(btrim(beer_style), '') is not null;
  if coalesce(cardinality(v_styles), 0) < 2 then return; end if;
  for r in
    select name, brewery, initcap(lower(btrim(beer_style))) as style from public.beers
    where nullif(btrim(beer_style), '') is not null order by random() limit 4
  loop
    v_m := public._throne_mc(r.style, v_styles, p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'beer_style',
        format('Which beer style is %s%s?', r.name, coalesce(' (' || nullif(btrim(r.brewery), '') || ')', '')), null, v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_beer_brewery(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
  v_b text[];
begin
  select array_agg(distinct btrim(brewery)) into v_b from public.beers where nullif(btrim(brewery), '') is not null;
  if coalesce(cardinality(v_b), 0) < 2 then return; end if;
  for r in select name, btrim(brewery) as brewery from public.beers where nullif(btrim(brewery), '') is not null order by random() limit 3 loop
    v_m := public._throne_mc(r.brewery, v_b, p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'beer_brewery', format('Which brewery makes %s?', r.name), null, v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_beer_best_rated(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  i int;
  v_names text[];
  v_m jsonb;
begin
  for i in 1..3 loop
    select array_agg(name order by avg_r desc) into v_names from (
      select name, avg_r from (
        select distinct on (avg_r) name, avg_r from (
          select b.name, round(avg(r.rating), 1) as avg_r
          from public.beers b join public.beer_ratings r on r.beer_id = b.id
          where r.rating is not null group by b.id, b.name
        ) ba order by avg_r, random()
      ) d order by random() limit greatest(p_opts, 3)
    ) pick;
    if coalesce(cardinality(v_names), 0) < 3 then return; end if;
    v_m := public._throne_mc(v_names[1], v_names[2:cardinality(v_names)], p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'beer_best_rated',
        'Which of these beers has the highest average rating in our app?', null, v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_beer_best_rater(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
  v_names text[] := public._throne_member_names();
begin
  if cardinality(v_names) < 2 then return; end if;
  for r in
    select name, top_user from (
      select b.name,
             (array_agg(pr.display_name order by u.a desc))[1] as top_user,
             (array_agg(u.a order by u.a desc))[1] as top_a,
             (array_agg(u.a order by u.a desc))[2] as second_a
      from public.beers b
      join (select beer_id, user_id, avg(rating) a from public.beer_ratings where rating is not null group by beer_id, user_id) u on u.beer_id = b.id
      join public.profiles pr on pr.id = u.user_id
      group by b.id, b.name
      having count(*) >= 2
    ) x where top_a > second_a order by random() limit 3
  loop
    v_m := public._throne_mc(r.top_user, v_names, p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'beer_best_rater', format('Who gave %s the highest rating?', r.name), null, v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_beer_session(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
  v_labels text[];
begin
  -- a session is only usable when its label ("12 Mar 2026 · Pub") is unique
  select array_agg(label) into v_labels from (
    select to_char(s.session_date, 'DD Mon YYYY') || coalesce(' · ' || nullif(btrim(s.location), ''), '') as label
    from public.beer_sessions s
  ) l where label in (
    select to_char(s2.session_date, 'DD Mon YYYY') || coalesce(' · ' || nullif(btrim(s2.location), ''), '')
    from public.beer_sessions s2
    group by 1 having count(*) = 1
  );
  if coalesce(cardinality(v_labels), 0) < 2 then return; end if;

  for r in
    with sl as (
      select s.id, to_char(s.session_date, 'DD Mon YYYY') || coalesce(' · ' || nullif(btrim(s.location), ''), '') as label
      from public.beer_sessions s
    ), bs as (
      select beer_id, session_id from public.beer_ratings where session_id is not null
      union select beer_id, session_id from public.beer_consumption where session_id is not null
    )
    select b.name, sl.label
    from public.beers b
    join bs on bs.beer_id = b.id
    join sl on sl.id = bs.session_id
    where b.id in (select beer_id from bs group by beer_id having count(*) = 1)
      and sl.label = any (v_labels)
    order by random() limit 3
  loop
    v_m := public._throne_mc(r.label, v_labels, p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'beer_session', format('In which Beer Session was %s drunk?', r.name), null, v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- Higher or Lower: show beer A (with its average), then beer B (without)
create or replace function public._tq_higher_lower(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_higher boolean;
begin
  for r in
    with ba as (
      select b.id, b.name, b.brewery, b.beer_style, round(avg(rt.rating), 1) as avg_r
      from public.beers b join public.beer_ratings rt on rt.beer_id = b.id
      where rt.rating is not null group by b.id, b.name, b.brewery, b.beer_style
    )
    select a.name an, a.brewery abr, a.beer_style ast, a.avg_r aavg, b.name bn, b.brewery bbr, b.beer_style bst, b.avg_r bavg
    from ba a join ba b on a.id <> b.id and abs(a.avg_r - b.avg_r) >= 0.5
    order by random() limit 8
  loop
    v_higher := r.bavg > r.aavg;
    return next row(md5(random()::text || r.an || r.bn), null, 'mc', 'higher_lower',
      'Does Beer B have a higher or lower average rating in our app than Beer A?',
      jsonb_build_object('layout', 'higher_lower',
        'a', jsonb_build_object('name', r.an, 'brewery', r.abr, 'style', r.ast, 'avg', r.aavg),
        'b', jsonb_build_object('name', r.bn, 'brewery', r.bbr, 'style', r.bst)),
      jsonb_build_array(jsonb_build_object('id', 'a', 'label', 'Higher'), jsonb_build_object('id', 'b', 'label', 'Lower')),
      jsonb_build_object('id', case when v_higher then 'a' else 'b' end))::public.throne_question_t;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- Guess the Beer: hints with the name hidden, choose from real beers
create or replace function public._tq_guess_beer(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_hints jsonb;
  v_wrongs text[];
  v_m jsonb;
begin
  for r in
    select b.id, b.name, b.brewery, initcap(lower(btrim(b.beer_style))) as style, b.alcohol_percentage as abv,
           (select round(avg(rating), 1) from public.beer_ratings where beer_id = b.id and rating is not null) as avg_r
    from public.beers b where nullif(btrim(b.beer_style), '') is not null
    order by random() limit 5
  loop
    v_hints := jsonb_build_array(jsonb_build_object('label', 'Style', 'value', r.style));
    if nullif(btrim(r.brewery), '') is not null
       and position(lower(r.name) in lower(r.brewery)) = 0
       and not ((r.abv is not null or r.avg_r is not null) and random() < 0.3) then
      v_hints := v_hints || jsonb_build_object('label', 'Brewery', 'value', btrim(r.brewery));
    end if;
    if r.abv is not null then
      v_hints := v_hints || jsonb_build_object('label', 'ABV', 'value', trim(trailing '.' from trim(trailing '0' from r.abv::text)) || '%');
    end if;
    if r.avg_r is not null then
      v_hints := v_hints || jsonb_build_object('label', 'Average rating', 'value', r.avg_r::text || ' / 10');
    end if;
    continue when jsonb_array_length(v_hints) < 2;

    select array_agg(name) into v_wrongs from (
      select name from public.beers where id <> r.id
      order by (lower(btrim(coalesce(beer_style, ''))) = lower(r.style)) desc, random()
      limit greatest(p_opts, 3) - 1
    ) w;
    v_m := public._throne_mc(r.name, v_wrongs, p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'guess_beer', 'Which beer is this?',
        jsonb_build_object('layout', 'guess', 'hints', v_hints), v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- ---------- 📜 lore templates ----------
create or replace function public._tq_nick_who(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
begin
  for r in
    select btrim(n.nickname) as nick, btrim(n.person_real_name) as person from public.nicknames n
    where n.status <> 'Gearchiveerd'
      and (select count(*) from public.nicknames x where lower(btrim(x.nickname)) = lower(btrim(n.nickname))) = 1
    order by random() limit 4
  loop
    v_m := public._throne_mc(r.person, public._throne_other_people(r.person), p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'nick_who', format('Who has the nickname “%s”?', r.nick), null, v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_nick_of_person(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
  v_wrongs text[];
begin
  for r in
    select btrim(max(nickname)) as nick, btrim(person_real_name) as person from public.nicknames
    where status <> 'Gearchiveerd' group by btrim(person_real_name) having count(*) = 1 order by random() limit 4
  loop
    select array_agg(btrim(nickname)) into v_wrongs from public.nicknames
      where lower(split_part(btrim(person_real_name), ' ', 1)) <> lower(split_part(r.person, ' ', 1));
    v_m := public._throne_mc(r.nick, v_wrongs, p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'nick_of_person', format('Which nickname belongs to %s?', r.person), null, v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- "Which nickname belongs to this story?"
create or replace function public._tq_nick_anecdote(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
  v_wrongs text[];
begin
  for r in
    select btrim(nickname) as nick, btrim(anecdote) as story, btrim(person_real_name) as person from public.nicknames
    where length(btrim(coalesce(anecdote, ''))) >= 20
      and position(lower(btrim(nickname)) in lower(anecdote)) = 0
      and not public._throne_mentions(anecdote, person_real_name)
    order by random() limit 3
  loop
    select array_agg(btrim(nickname)) into v_wrongs from public.nicknames where lower(btrim(nickname)) <> lower(r.nick);
    v_m := public._throne_mc(r.nick, v_wrongs, p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'nick_anecdote', 'Which nickname belongs to this story?',
        jsonb_build_object('layout', 'quote', 'text', public._throne_clip(r.story, 260)), v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- "Which colleague does this story belong to?"
create or replace function public._tq_nickstory_who(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
begin
  for r in
    select btrim(anecdote) as story, btrim(person_real_name) as person from public.nicknames
    where length(btrim(coalesce(anecdote, ''))) >= 20
      and not public._throne_mentions(anecdote, person_real_name)
    order by random() limit 3
  loop
    v_m := public._throne_mc(r.person, public._throne_other_people(r.person), p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'nickstory_who', 'Which colleague does this story belong to?',
        jsonb_build_object('layout', 'quote', 'text', public._throne_clip(r.story, 260)), v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- "Which of these nicknames is really on the Nickname Wall?"
create or replace function public._tq_nick_real(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
  v_fakes text[] := array['Captain Foam', 'The Stapler Whisperer', 'Sir Reply-All', 'Coffee Goblin', 'Meeting Ghost',
                          'Duke of Excel', 'Printer Whisperer', 'The Last Biscuit', 'Lord of the Lanyards', 'Baron von Agenda'];
begin
  for r in select btrim(nickname) as nick from public.nicknames where status <> 'Gearchiveerd' order by random() limit 3 loop
    v_m := public._throne_mc(r.nick, v_fakes, p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'nick_real', 'Which of these nicknames is really on our Nickname Wall?', null, v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_quote_who(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
begin
  for r in
    select btrim(quote) as q, btrim(person_real_name) as person, nullif(btrim(context), '') as ctx from public.quotes
    where length(btrim(quote)) >= 8 and not public._throne_mentions(quote, person_real_name)
    order by random() limit 4
  loop
    v_m := public._throne_mc(r.person, public._throne_other_people(r.person), p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'quote_who', 'Who said this?',
        jsonb_build_object('layout', 'quote', 'text', '“' || public._throne_clip(r.q, 240) || '”'), v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_anecdote_who(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
begin
  for r in
    select btrim(title) as title, btrim(description) as descr, btrim(person_real_name) as person from public.anecdotes
    where length(btrim(description)) >= 15
      and not public._throne_mentions(title || ' ' || description, person_real_name)
    order by random() limit 3
  loop
    v_m := public._throne_mc(r.person, public._throne_other_people(r.person), p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'anecdote_who', 'Whose anecdote is this?',
        jsonb_build_object('layout', 'quote', 'title', r.title, 'text', public._throne_clip(r.descr, 240)), v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_poem_author(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
  v_names text[] := public._throne_member_names();
begin
  if cardinality(v_names) < 2 then return; end if;
  for r in
    select btrim(p.title) as title, btrim(p.content) as content, pr.display_name as author
    from public.poems p join public.profiles pr on pr.id = p.author_user_id
    where length(btrim(p.content)) >= 30
      and not public._throne_mentions(p.title || ' ' || p.content, pr.display_name)
    order by random() limit 4
  loop
    v_m := public._throne_mc(r.author, v_names, p_opts);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'poem_author', 'Who wrote this poem?',
        jsonb_build_object('layout', 'quote', 'title', r.title, 'text', public._throne_clip(r.content, 200)), v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_battle_winner(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  r record;
  v_m jsonb;
begin
  for r in
    select nickname_a_text as a, nickname_b_text as b, winner_nickname_text as w from public.nickname_battles
    where status = 'finished' and winner_nickname_text is not null and nickname_a_text <> nickname_b_text
      and winner_nickname_text in (nickname_a_text, nickname_b_text)
    order by random() limit 3
  loop
    v_m := public._throne_mc(r.w, array[case when r.w = r.a then r.b else r.a end], 2);
    if v_m is not null then
      return next public._tq_row(null, null, 'mc', 'battle_winner',
        format('Nickname Battle: “%s” vs “%s”. Which one won?', r.a, r.b), null, v_m);
    end if;
  end loop;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- ---------- 🧠 count questions (multiple choice) ----------
create or replace function public._tq_count_sessions(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare v_n bigint := (select count(*) from public.beer_sessions);
begin
  if v_n >= 1 then
    return next public._tq_row(null, null, 'mc', 'count_sessions', 'How many Beer Sessions have we had?', null, public._throne_num_mc(v_n, p_opts));
  end if;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_count_beers(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare v_n bigint := (select count(*) from public.beers);
begin
  if v_n >= 1 then
    return next public._tq_row(null, null, 'mc', 'count_beers', 'How many different beers are registered in the app?', null, public._throne_num_mc(v_n, p_opts));
  end if;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_count_nicknames(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare v_n bigint := (select count(*) from public.nicknames);
begin
  if v_n >= 1 then
    return next public._tq_row(null, null, 'mc', 'count_nicknames', 'How many nicknames are on the Nickname Wall?', null, public._throne_num_mc(v_n, p_opts));
  end if;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_count_poems(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare v_n bigint := (select count(*) from public.poems);
begin
  if v_n >= 1 then
    return next public._tq_row(null, null, 'mc', 'count_poems', 'How many poems are on the Poetry Wall?', null, public._throne_num_mc(v_n, p_opts));
  end if;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- ---------- 🧠 Closest Wins: numeric questions ----------
create or replace function public._tq_num_counts(p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  v_n bigint;
  r record;
begin
  select count(*) into v_n from public.beers;
  if v_n > 0 then return next public._tq_num_row('num_beers', 'How many different beers are registered in the app?', v_n, 'beers'); end if;
  select count(*) into v_n from public.beer_ratings where rating is not null;
  if v_n > 0 then return next public._tq_num_row('num_ratings', 'How many beer ratings have we given in total?', v_n, 'ratings'); end if;
  select count(*) into v_n from public.nicknames;
  if v_n > 0 then return next public._tq_num_row('num_nicknames', 'How many nicknames are on the Nickname Wall?', v_n, 'nicknames'); end if;
  select count(*) into v_n from public.beer_sessions;
  if v_n > 0 then return next public._tq_num_row('num_sessions', 'How many Beer Sessions have we had?', v_n, 'sessions'); end if;
  select count(*) into v_n from public.poems;
  if v_n > 0 then return next public._tq_num_row('num_poems', 'How many poems are on the Poetry Wall?', v_n, 'poems'); end if;
  select count(*) into v_n from public.nickname_battles;
  if v_n > 0 then return next public._tq_num_row('num_battles', 'How many Nickname Battles have been fought?', v_n, 'battles'); end if;

  -- about a random member
  select p.id, p.display_name into r from public.profiles p
    join public.app_memberships m on m.user_id = p.id and m.app_id = 'officelore' and m.is_active = true
    order by random() limit 1;
  if r.id is not null then
    if (select count(*) from public.perfect_pours) > 0 then
      select count(*) into v_n from public.perfect_pours where received_by_user_id = r.id;
      return next public._tq_num_row('num_pp_user', format('How many Perfect Pours has %s received?', r.display_name), v_n, 'Perfect Pours');
    end if;
    select count(distinct beer_id) into v_n from public.beer_ratings where user_id = r.id and rating is not null;
    if v_n > 0 then return next public._tq_num_row('num_ratings_user', format('How many different beers has %s rated?', r.display_name), v_n, 'beers'); end if;
    select count(*) into v_n from public.poems where author_user_id = r.id;
    if v_n > 0 then return next public._tq_num_row('num_poems_user', format('How many poems has %s written?', r.display_name), v_n, 'poems'); end if;
  end if;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- ---------- 🧠 Know Thy Enemy: mirrored questions about the opponent ----------
-- _enemy_q builds ONE question about p_subject, to be asked to p_asker
create or replace function public._enemy_q(p_kind text, p_subject uuid, p_asker uuid, p_opts int)
returns public.throne_question_t as $$
declare
  v_name text;
  v_top text; v_a1 numeric; v_a2 numeric;
  v_n bigint;
  v_wrongs text[];
  v_m jsonb;
  v_possessive text;
begin
  select display_name into v_name from public.profiles where id = p_subject;
  if v_name is null then return null; end if;
  v_possessive := v_name || '''s';

  if p_kind = 'best_beer' then
    with s as (
      select b.name, round(avg(r.rating), 2) as a from public.beer_ratings r join public.beers b on b.id = r.beer_id
      where r.user_id = p_subject and r.rating is not null group by b.id, b.name)
    select (array_agg(name order by a desc))[1], (array_agg(a order by a desc))[1], (array_agg(a order by a desc))[2]
      into v_top, v_a1, v_a2 from s;
    if v_top is null or (v_a2 is not null and v_a1 = v_a2) then return null; end if;
    select array_agg(name) into v_wrongs from public.beers where name <> v_top;
    v_m := public._throne_mc(v_top, v_wrongs, p_opts);
    if v_m is null then return null; end if;
    return public._tq_row(null, p_asker, 'mc', 'enemy_best_beer', format('What is %s highest rated beer?', v_possessive), null, v_m);

  elsif p_kind = 'fav_style' then
    with s as (
      select initcap(lower(btrim(b.beer_style))) as st, round(avg(r.rating), 2) as a
      from public.beer_ratings r join public.beers b on b.id = r.beer_id
      where r.user_id = p_subject and r.rating is not null and nullif(btrim(b.beer_style), '') is not null group by 1)
    select (array_agg(st order by a desc))[1], (array_agg(a order by a desc))[1], (array_agg(a order by a desc))[2]
      into v_top, v_a1, v_a2 from s;
    if v_top is null or v_a2 is null or v_a1 = v_a2 then return null; end if;
    select array_agg(distinct initcap(lower(btrim(beer_style)))) into v_wrongs from public.beers where nullif(btrim(beer_style), '') is not null;
    v_m := public._throne_mc(v_top, v_wrongs, p_opts);
    if v_m is null then return null; end if;
    return public._tq_row(null, p_asker, 'mc', 'enemy_fav_style', format('Which beer style does %s rate highest on average?', v_name), null, v_m);

  elsif p_kind = 'rating_count' then
    select count(distinct beer_id) into v_n from public.beer_ratings where user_id = p_subject and rating is not null;
    if v_n < 1 then return null; end if;
    v_m := public._throne_num_mc(v_n, p_opts);
    if v_m is null then return null; end if;
    return public._tq_row(null, p_asker, 'mc', 'enemy_rating_count', format('How many different beers has %s rated?', v_name), null, v_m);

  elsif p_kind = 'perfect_pours' then
    if (select count(*) from public.perfect_pours) < 1 then return null; end if;
    select count(*) into v_n from public.perfect_pours where received_by_user_id = p_subject;
    v_m := public._throne_num_mc(v_n, p_opts);
    if v_m is null then return null; end if;
    return public._tq_row(null, p_asker, 'mc', 'enemy_perfect_pours', format('How many Perfect Pours has %s received?', v_name), null, v_m);

  elsif p_kind = 'nickname' then
    select count(*), max(btrim(n.nickname)) into v_n, v_top
      from public.nicknames n join public.profiles pr on pr.id = p_subject
      where lower(btrim(n.person_real_name)) in (lower(btrim(coalesce(pr.first_name, ''))), lower(btrim(pr.display_name)), lower(btrim(coalesce(pr.profile_nickname, ''))))
        and btrim(n.person_real_name) <> '';
    if v_n <> 1 then return null; end if;
    select array_agg(btrim(nickname)) into v_wrongs from public.nicknames where lower(btrim(nickname)) <> lower(v_top);
    v_m := public._throne_mc(v_top, v_wrongs, p_opts);
    if v_m is null then return null; end if;
    return public._tq_row(null, p_asker, 'mc', 'enemy_nickname', format('Which nickname is on the Wall for %s?', v_name), null, v_m);

  elsif p_kind = 'poems' then
    select count(*) into v_n from public.poems where author_user_id = p_subject;
    if v_n < 1 then return null; end if;
    v_m := public._throne_num_mc(v_n, p_opts);
    if v_m is null then return null; end if;
    return public._tq_row(null, p_asker, 'mc', 'enemy_poems', format('How many poems has %s written?', v_name), null, v_m);

  elsif p_kind = 'sessions' then
    select count(*) into v_n from public.beer_session_participants where user_id = p_subject;
    if v_n < 1 then return null; end if;
    v_m := public._throne_num_mc(v_n, p_opts);
    if v_m is null then return null; end if;
    return public._tq_row(null, p_asker, 'mc', 'enemy_sessions', format('At how many Beer Sessions was %s present?', v_name), null, v_m);
  end if;
  return null;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- one pair: the same template asked about the opponent, to both players
create or replace function public._tq_enemy_pair(p_kind text, p_chal uuid, p_def uuid, p_opts int)
returns setof public.throne_question_t as $$
declare
  qa public.throne_question_t;
  qb public.throne_question_t;
  v_grp text := md5(random()::text || clock_timestamp()::text || p_kind);
begin
  qa := public._enemy_q(p_kind, p_def, p_chal, p_opts); -- the challenger is asked about the defender
  qb := public._enemy_q(p_kind, p_chal, p_def, p_opts); -- the defender is asked about the challenger
  if qa.prompt is null or qb.prompt is null then return; end if;
  qa.grp := v_grp; qb.grp := v_grp;
  return next qa;
  return next qb;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._tq_enemy_best_beer(p_chal uuid, p_def uuid, p_opts int) returns setof public.throne_question_t as $$
  select * from public._tq_enemy_pair('best_beer', p_chal, p_def, p_opts);
$$ language sql volatile security definer set search_path = public;
create or replace function public._tq_enemy_fav_style(p_chal uuid, p_def uuid, p_opts int) returns setof public.throne_question_t as $$
  select * from public._tq_enemy_pair('fav_style', p_chal, p_def, p_opts);
$$ language sql volatile security definer set search_path = public;
create or replace function public._tq_enemy_rating_count(p_chal uuid, p_def uuid, p_opts int) returns setof public.throne_question_t as $$
  select * from public._tq_enemy_pair('rating_count', p_chal, p_def, p_opts);
$$ language sql volatile security definer set search_path = public;
create or replace function public._tq_enemy_perfect_pours(p_chal uuid, p_def uuid, p_opts int) returns setof public.throne_question_t as $$
  select * from public._tq_enemy_pair('perfect_pours', p_chal, p_def, p_opts);
$$ language sql volatile security definer set search_path = public;
create or replace function public._tq_enemy_nickname(p_chal uuid, p_def uuid, p_opts int) returns setof public.throne_question_t as $$
  select * from public._tq_enemy_pair('nickname', p_chal, p_def, p_opts);
$$ language sql volatile security definer set search_path = public;
create or replace function public._tq_enemy_poems(p_chal uuid, p_def uuid, p_opts int) returns setof public.throne_question_t as $$
  select * from public._tq_enemy_pair('poems', p_chal, p_def, p_opts);
$$ language sql volatile security definer set search_path = public;
create or replace function public._tq_enemy_sessions(p_chal uuid, p_def uuid, p_opts int) returns setof public.throne_question_t as $$
  select * from public._tq_enemy_pair('sessions', p_chal, p_def, p_opts);
$$ language sql volatile security definer set search_path = public;

-- =================================================================
-- SECTION 4 — question generation: the generic part
-- =================================================================
create or replace function public._prepare_throne_trial(p_trial_id uuid, p_cat public.throne_trial_catalog)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  cfg jsonb := coalesce(p_cat.public_config, '{}'::jsonb);
  v_count int := coalesce((cfg->>'count')::int, 5);
  v_opts int := coalesce((cfg->>'options')::int, 4);
  v_fb text := coalesce(cfg->>'fallback', 'beer');
  v_short boolean := coalesce((cfg->>'short')::boolean, false);
  v_pool jsonb := '[]'::jsonb;
  v_rows jsonb;
  v_tpl text;
  v_m jsonb;
  b record;
  v_n int;
begin
  select * into t from public.throne_challenge_trials where id = p_trial_id;
  select * into c from public.throne_challenges where id = t.challenge_id;

  -- 1. own data: every template named in the catalog row (a failing template
  --    is skipped, never fatal)
  for v_tpl in select jsonb_array_elements_text(coalesce(cfg->'templates', '[]'::jsonb)) loop
    continue when v_tpl !~ '^[a-z_]+$';
    begin
      execute format('select coalesce(jsonb_agg(to_jsonb(q)), ''[]''::jsonb) from public.%I($1, $2, $3) q', '_tq_' || v_tpl)
        into v_rows using c.challenger_user_id, c.defender_user_id, v_opts;
      v_pool := v_pool || v_rows;
    exception when others then
      raise warning 'throne template % failed: %', v_tpl, sqlerrm;
    end;
  end loop;

  -- 2. built-in trivia: always offered, but only used last (top-up)
  for b in
    select * from public.throne_builtin_trivia
    where (v_fb = 'any' or category = v_fb) and (not v_short or short)
    order by random() limit v_count
  loop
    v_m := public._throne_mc(b.correct, b.wrongs, v_opts);
    if v_m is not null then
      v_pool := v_pool || to_jsonb(public._tq_row(null, null, 'mc', 'builtin', b.prompt, null, v_m));
    end if;
  end loop;

  -- 3. pick `count` groups, round-robin over tags for variety (built-in last),
  --    and store one copy of the questions per player, same order for both
  with pool as (
    select * from jsonb_populate_recordset(null::public.throne_question_t, v_pool)
  ), grps as (
    select grp, min(tag) as tag, row_number() over (partition by min(tag) order by random()) as r_tag
    from pool group by grp
  ), chosen as (
    select grp, ord from (
      select grp, row_number() over (order by (tag = 'builtin'), r_tag, random()) as ord from grps
    ) x where ord <= v_count
  )
  insert into public.throne_trial_questions (trial_id, user_id, seq, kind, tag, prompt, facts, options, answer)
  select p_trial_id, u.uid,
         row_number() over (partition by u.uid order by ch.ord),
         q.kind, q.tag, q.prompt, q.facts, q.options, q.answer
  from chosen ch
  join pool q on q.grp = ch.grp
  cross join (values (c.challenger_user_id), (c.defender_user_id)) as u(uid)
  where q.for_user_id is null or q.for_user_id = u.uid;

  select count(*) into v_n from public.throne_trial_questions where trial_id = p_trial_id and user_id = c.challenger_user_id;
  if v_n < 1 then
    raise exception 'Could not build any questions for this Trial';
  end if;
  update public.throne_challenge_trials
    set public_config = public_config || jsonb_build_object('question_count', v_n)
    where id = p_trial_id;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- hook: every Trial of a quiz-type resolution gets its questions at start
create or replace function public._start_throne_trial(p_challenge_id uuid, p_cat public.throne_trial_catalog, p_picker uuid)
returns uuid as $$
declare
  v_no int;
  v_id uuid;
  v_status text;
begin
  select count(*) + 1 into v_no from public.throne_challenge_trials where challenge_id = p_challenge_id;
  v_status := case when p_cat.resolution = 'judge' then 'awaiting_judge' else 'active' end;

  insert into public.throne_challenge_trials
    (challenge_id, trial_no, picker_user_id, school, catalog_id, title, description, resolution, public_config, status)
  values
    (p_challenge_id, v_no, p_picker, p_cat.school, p_cat.id, p_cat.title, p_cat.description, p_cat.resolution, p_cat.public_config, v_status)
  returning id into v_id;

  if p_cat.resolution in ('quiz', 'timed', 'streak') then
    perform public._prepare_throne_trial(v_id, p_cat);
  end if;

  update public.throne_challenges
    set status = v_status,
        awaiting_pick_by = null,
        started_at = coalesce(started_at, now()),
        step_deadline = now() + interval '48 hours'
    where id = p_challenge_id;

  return v_id;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — runs: start / answer / finish / resolve
-- =================================================================
create or replace function public._throne_run_state(p_trial_id uuid, p_user uuid)
returns jsonb as $$
declare
  t public.throne_challenge_trials;
  r public.throne_trial_runs;
  v_state text;
  v_q jsonb := '[]'::jsonb;
  v_dur int;
begin
  select * into t from public.throne_challenge_trials where id = p_trial_id;
  select * into r from public.throne_trial_runs where trial_id = p_trial_id and user_id = p_user;
  v_dur := case when t.resolution = 'timed' then coalesce((t.public_config->>'duration_s')::int, 60) else 0 end;
  v_state := case when r.trial_id is null then 'not_started' when r.finished_at is not null then 'finished' else 'running' end;

  if v_state = 'running' then
    select coalesce(jsonb_agg(jsonb_build_object('seq', seq, 'kind', kind, 'prompt', prompt, 'facts', facts, 'options', options) order by seq), '[]'::jsonb)
      into v_q from public.throne_trial_questions where trial_id = p_trial_id and user_id = p_user;
  end if;

  return jsonb_build_object(
    'state', v_state,
    'mode', t.resolution,
    'scoring', t.public_config->>'scoring',
    'duration_s', v_dur,
    'started_at', r.started_at,
    'ends_at', case when v_dur > 0 and r.started_at is not null then r.started_at + make_interval(secs => v_dur) end,
    'server_now', clock_timestamp(),
    'total', (select count(*) from public.throne_trial_questions where trial_id = p_trial_id and user_id = p_user),
    'answered', coalesce(r.answered, 0),
    'correct', coalesce(r.correct, 0),
    'wrong', coalesce(r.wrong, 0),
    'ended_by', r.ended_by,
    'questions', v_q
  );
end;
$$ language plpgsql stable security definer set search_path = public;

-- ends a run; when both players are done the Trial resolves by itself
create or replace function public._finalize_throne_run(p_trial_id uuid, p_user uuid, p_ended_by text)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
begin
  perform pg_advisory_xact_lock(918273645);
  update public.throne_trial_runs
    set finished_at = clock_timestamp(), ended_by = p_ended_by
    where trial_id = p_trial_id and user_id = p_user and finished_at is null;
  if not found then
    return;
  end if;

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if p_user = c.challenger_user_id then
    update public.throne_challenge_trials set challenger_submitted = true where id = t.id;
  else
    update public.throne_challenge_trials set defender_submitted = true where id = t.id;
  end if;

  if t.status = 'active'
     and exists (select 1 from public.throne_trial_runs where trial_id = t.id and user_id = c.challenger_user_id and finished_at is not null)
     and exists (select 1 from public.throne_trial_runs where trial_id = t.id and user_id = c.defender_user_id and finished_at is not null) then
    perform public._resolve_quiz_trial(t.id);
  end if;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- the automatic judge
create or replace function public._resolve_quiz_trial(p_trial_id uuid)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  r1 public.throne_trial_runs;
  r2 public.throne_trial_runs;
  v_scoring text;
  v_a numeric[];
  v_b numeric[];
  v_winner uuid;
  v_decided text;
begin
  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.status = 'completed' then return; end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  select * into r1 from public.throne_trial_runs where trial_id = t.id and user_id = c.challenger_user_id;
  select * into r2 from public.throne_trial_runs where trial_id = t.id and user_id = c.defender_user_id;
  v_scoring := coalesce(t.public_config->>'scoring', case t.resolution when 'timed' then 'timed' when 'streak' then 'streak' else 'correct' end);

  -- lexicographic keys, higher is better; the 2nd element is the tie-break
  if v_scoring = 'error' then
    v_a := array[-r1.err_sum, -r1.total_ms]; v_b := array[-r2.err_sum, -r2.total_ms];
  elsif v_scoring = 'timed' then
    v_a := array[r1.correct - r1.wrong, -r1.wrong]; v_b := array[r2.correct - r2.wrong, -r2.wrong];
  else
    v_a := array[r1.correct, -r1.total_ms]; v_b := array[r2.correct, -r2.total_ms];
  end if;

  if v_a > v_b then v_winner := c.challenger_user_id;
  elsif v_b > v_a then v_winner := c.defender_user_id;
  else v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
  end if;
  v_decided := case when v_a[1] <> v_b[1] then 'score' when v_a[2] <> v_b[2] then 'tiebreak' else 'coin' end;

  update public.throne_challenge_trials
    set challenger_result = jsonb_build_object('correct', r1.correct, 'wrong', r1.wrong, 'answered', r1.answered,
          'total_ms', r1.total_ms, 'err_sum', round(r1.err_sum, 4), 'ended_by', r1.ended_by),
        defender_result = jsonb_build_object('correct', r2.correct, 'wrong', r2.wrong, 'answered', r2.answered,
          'total_ms', r2.total_ms, 'err_sum', round(r2.err_sum, 4), 'ended_by', r2.ended_by),
        reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('scoring', v_scoring, 'decided_by', v_decided,
          'total', (select count(*) from public.throne_trial_questions where trial_id = t.id and user_id = c.challenger_user_id))
    where id = t.id;
  perform public._finish_throne_trial(t.id, v_winner);
end;
$$ language plpgsql volatile security definer set search_path = public;

-- timed runs whose hourglass ran out (the player closed the app): close them
create or replace function public._finalize_expired_runs()
returns boolean as $$
declare
  r record;
  v_changed boolean := false;
begin
  for r in
    select ru.trial_id, ru.user_id
    from public.throne_trial_runs ru
    join public.throne_challenge_trials t on t.id = ru.trial_id
    where ru.finished_at is null and t.status = 'active' and t.resolution = 'timed'
      and clock_timestamp() > ru.started_at + make_interval(secs => coalesce((t.public_config->>'duration_s')::int, 60) + 2)
  loop
    perform public._finalize_throne_run(r.trial_id, r.user_id, 'time');
    v_changed := true;
  end loop;
  return v_changed;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public.get_throne_run(p_trial_id uuid)
returns jsonb as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id;
  if t.id is null or t.resolution not in ('quiz', 'timed', 'streak') then raise exception 'Not a question Trial'; end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() not in (c.challenger_user_id, c.defender_user_id) then raise exception 'Only the two duelists can play this Trial'; end if;
  if t.status = 'completed' then
    return public._throne_run_state(t.id, auth.uid()) || jsonb_build_object('state', 'finished');
  end if;
  return public._throne_run_state(t.id, auth.uid());
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.start_throne_run(p_trial_id uuid)
returns jsonb as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.id is null or t.status <> 'active' or t.resolution not in ('quiz', 'timed', 'streak') then
    raise exception 'This Trial is not open for play';
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() not in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'Only the two duelists can play this Trial';
  end if;

  -- idempotent: a second call (refresh, double tap) returns the SAME run
  insert into public.throne_trial_runs (trial_id, user_id, started_at, last_at)
    values (t.id, auth.uid(), clock_timestamp(), clock_timestamp())
    on conflict (trial_id, user_id) do nothing;
  return public._throne_run_state(t.id, auth.uid());
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public.answer_throne_question(p_trial_id uuid, p_seq int, p_choice jsonb)
returns jsonb as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  r public.throne_trial_runs;
  q public.throne_trial_questions;
  v_total int;
  v_correct boolean;
  v_err numeric := 0;
  v_guess numeric;
  v_ans numeric;
  v_ms int;
  v_id text;
  v_reveal jsonb;
  v_dur int;
  v_ended text;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.id is null or t.status <> 'active' or t.resolution not in ('quiz', 'timed', 'streak') then
    raise exception 'This Trial is not open for answers';
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() not in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'Only the two duelists can play this Trial';
  end if;

  select * into r from public.throne_trial_runs where trial_id = t.id and user_id = auth.uid() for update;
  if r.trial_id is null then raise exception 'You have not started this Trial'; end if;
  if r.finished_at is not null then raise exception 'You have already finished this Trial'; end if;

  if t.resolution = 'timed' then
    v_dur := coalesce((t.public_config->>'duration_s')::int, 60);
    if clock_timestamp() > r.started_at + make_interval(secs => v_dur + 2) then
      perform public._finalize_throne_run(t.id, auth.uid(), 'time');
      return jsonb_build_object('finished', true, 'expired', true);
    end if;
  end if;

  if p_seq is distinct from r.answered + 1 then raise exception 'Answer the questions in order'; end if;
  select * into q from public.throne_trial_questions where trial_id = t.id and user_id = auth.uid() and seq = p_seq;
  if q.trial_id is null then raise exception 'Unknown question'; end if;
  select count(*) into v_total from public.throne_trial_questions where trial_id = t.id and user_id = auth.uid();

  if q.kind = 'numeric' then
    begin
      v_guess := (p_choice->>'value')::numeric;
    exception when others then
      v_guess := null;
    end;
    if v_guess is null then raise exception 'Enter a number'; end if;
    v_ans := (q.answer->>'value')::numeric;
    v_err := abs(v_guess - v_ans) / greatest(abs(v_ans), 1);
    v_correct := (v_guess = v_ans);
    v_reveal := jsonb_build_object('value', v_ans);
  else
    v_id := p_choice->>'id';
    if v_id is null or not (q.options @> jsonb_build_array(jsonb_build_object('id', v_id))) then
      raise exception 'Unknown option';
    end if;
    v_correct := (v_id = q.answer->>'id');
    v_reveal := q.answer;
  end if;

  v_ms := least(2000000000, greatest(0, round(extract(epoch from (clock_timestamp() - coalesce(r.last_at, r.started_at))) * 1000)))::int;
  insert into public.throne_trial_answers (trial_id, user_id, seq, choice, correct, err, ms)
    values (t.id, auth.uid(), p_seq, p_choice, v_correct, v_err, v_ms);
  update public.throne_trial_runs
    set answered = answered + 1,
        correct = correct + case when v_correct then 1 else 0 end,
        wrong = wrong + case when v_correct then 0 else 1 end,
        total_ms = total_ms + v_ms,
        err_sum = err_sum + v_err,
        last_at = clock_timestamp()
    where trial_id = t.id and user_id = auth.uid()
    returning * into r;

  if t.resolution = 'streak' and not v_correct then
    v_ended := 'wrong';
  elsif r.answered >= v_total then
    v_ended := 'complete';
  end if;
  if v_ended is not null then
    perform public._finalize_throne_run(t.id, auth.uid(), v_ended);
  end if;

  return jsonb_build_object('correct', v_correct, 'reveal', v_reveal, 'finished', v_ended is not null,
    'ended_by', v_ended, 'answered', r.answered, 'correct_count', r.correct, 'wrong_count', r.wrong);
end;
$$ language plpgsql security definer set search_path = public;

-- the hourglass ran out (Rapid Fire): the client says so, the server checks
create or replace function public.finish_throne_run(p_trial_id uuid)
returns jsonb as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  r public.throne_trial_runs;
  v_dur int;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.id is null or t.resolution <> 'timed' then raise exception 'This Trial has no hourglass'; end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() not in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'Only the two duelists can play this Trial';
  end if;
  select * into r from public.throne_trial_runs where trial_id = t.id and user_id = auth.uid() for update;
  if r.trial_id is null then raise exception 'You have not started this Trial'; end if;
  v_dur := coalesce((t.public_config->>'duration_s')::int, 60);
  if r.finished_at is null then
    if clock_timestamp() < r.started_at + make_interval(secs => v_dur - 1) then
      raise exception 'The hourglass is still running';
    end if;
    perform public._finalize_throne_run(t.id, auth.uid(), 'time');
  end if;
  return public._throne_run_state(t.id, auth.uid()) || jsonb_build_object('state', 'finished');
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 6 — deadline resolver (replaces 0038's; adds quiz-type handling)
-- =================================================================
create or replace function public._resolve_expired_throne_challenge()
returns boolean as $$
declare
  c public.throne_challenges;
  t public.throne_challenge_trials;
  v_cat public.throne_trial_catalog;
  v_winner uuid;
  v_changed boolean := false;
  v_guard int := 0;
begin
  perform pg_advisory_xact_lock(918273645);

  -- Rapid Fire runs whose time is up resolve first (may finish a Trial)
  if public._finalize_expired_runs() then
    v_changed := true;
  end if;

  loop
    v_guard := v_guard + 1;
    exit when v_guard > 10;

    select * into c from public.throne_challenges
      where status in ('pending', 'active', 'awaiting_judge')
        and step_deadline is not null and step_deadline <= now()
      limit 1;
    exit when c.id is null;
    v_changed := true;

    if c.status = 'pending' then
      -- the challenger never picked Trial 1's school: nothing was played, nobody lost
      update public.throne_challenges
        set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
        where id = c.id;

    elsif c.awaiting_pick_by is not null then
      -- the picker didn't choose a school in time: a random school is drawn
      v_cat := public._pick_catalog_trial(c.id, null);
      perform public._start_throne_trial(c.id, v_cat, c.awaiting_pick_by);

    else
      select * into t from public.throne_challenge_trials
        where challenge_id = c.id and status <> 'completed'
        order by trial_no desc limit 1;

      if t.id is null then
        -- inconsistent state: close it safely
        update public.throne_challenges
          set status = 'cancelled', completed_at = now(), awaiting_pick_by = null, step_deadline = null
          where id = c.id;
      else
        if t.resolution in ('quiz', 'timed', 'streak') then
          -- close any run still in progress with what it has; if that leaves
          -- both runs finished the Trial resolves on its own
          perform public._finalize_throne_run(t.id, c.challenger_user_id, 'deadline');
          perform public._finalize_throne_run(t.id, c.defender_user_id, 'deadline');
          select * into t from public.throne_challenge_trials where id = t.id;
          continue when t.status = 'completed';
        end if;

        if t.resolution = 'judge' then
          v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
        elsif t.challenger_submitted and not t.defender_submitted then
          v_winner := c.challenger_user_id; -- the non-responder forfeits
        elsif t.defender_submitted and not t.challenger_submitted then
          v_winner := c.defender_user_id;
        else
          v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
        end if;
        update public.throne_challenge_trials
          set reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('timeout', true)
          where id = t.id;
        perform public._finish_throne_trial(t.id, v_winner);
      end if;
    end if;
  end loop;

  return v_changed;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 7 — the Final Trial likes Sudden Death
-- =================================================================
-- Catalog rows with public_config.final_boost = true get a 40% chance of
-- being THE FINAL TRIAL (when unused and allowed); otherwise the throne
-- chooses at random as before.
create or replace function public._pick_final_throne_trial(p_challenge_id uuid)
returns public.throne_trial_catalog as $$
declare
  v_cat public.throne_trial_catalog;
begin
  if random() < 0.4 then
    select * into v_cat from public.throne_trial_catalog t
      where t.is_active and coalesce((t.public_config->>'final_boost')::boolean, false)
        and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
      order by random() limit 1;
    if v_cat.id is not null then
      return v_cat;
    end if;
  end if;
  return public._pick_catalog_trial(p_challenge_id, null);
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._finish_throne_trial(p_trial_id uuid, p_winner uuid)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_cat public.throne_trial_catalog;
  v_chal int;
  v_def int;
begin
  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.status = 'completed' then
    return;
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id for update;
  if p_winner not in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'Trial winner must be a participant';
  end if;

  update public.throne_challenge_trials
    set status = 'completed', winner_user_id = p_winner, completed_at = now()
    where id = t.id;

  v_chal := c.challenger_score + case when p_winner = c.challenger_user_id then 1 else 0 end;
  v_def := c.defender_score + case when p_winner = c.defender_user_id then 1 else 0 end;
  update public.throne_challenges set challenger_score = v_chal, defender_score = v_def where id = c.id;

  if v_chal >= 2 or v_def >= 2 then
    perform public._complete_throne_challenge(c.id, p_winner);
  elsif t.trial_no = 1 then
    update public.throne_challenges
      set status = 'active', awaiting_pick_by = c.defender_user_id, step_deadline = now() + interval '48 hours'
      where id = c.id;
  else
    v_cat := public._pick_final_throne_trial(c.id);
    perform public._start_throne_trial(c.id, v_cat, null);
  end if;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 8 — the game catalog (the registry)
-- =================================================================
-- the roll-the-dice REFLEX placeholders are retired now that REFLEX is real
update public.throne_trial_catalog set is_active = false where id in ('reflex_quick_draw', 'reflex_cap_flip');

insert into public.throne_trial_catalog (id, school, title, description, resolution, public_config) values
  ('pint_beer_trivia', 'pint', 'Beer Trivia',
   'Five multiple-choice questions about OUR beers: styles, ratings, who rated what, which Session. Most right answers wins.',
   'quiz', '{"count":5,"options":4,"scoring":"correct","fallback":"beer","templates":["beer_style","beer_best_rated","beer_best_rater","beer_session","beer_brewery"]}'),
  ('pint_higher_lower', 'pint', 'Higher or Lower',
   'Beer A is shown with its average rating in our app. Is Beer B rated higher or lower? Six rounds, most right wins.',
   'quiz', '{"count":6,"options":2,"scoring":"correct","fallback":"beer","templates":["higher_lower"]}'),
  ('pint_guess_beer', 'pint', 'Guess the Beer',
   'The name is hidden. Style, brewery, ABV and average rating are your clues. Four beers to identify.',
   'quiz', '{"count":4,"options":4,"scoring":"correct","fallback":"beer","templates":["guess_beer"]}'),
  ('lore_who_said_it', 'lore', 'Who Said It?',
   'Quotes, anecdotes and poems from the Office Lore. Who is behind each one? Most right answers wins.',
   'quiz', '{"count":5,"options":4,"scoring":"correct","fallback":"general","templates":["quote_who","anecdote_who","nickstory_who","poem_author"]}'),
  ('lore_nickname_knowledge', 'lore', 'Nickname Knowledge',
   'Who has this nickname? Which nickname is real? Which one belongs to this story? Five questions from the Nickname Wall.',
   'quiz', '{"count":5,"options":4,"scoring":"correct","fallback":"general","templates":["nick_who","nick_of_person","nick_anecdote","nick_real"]}'),
  ('lore_office_quiz', 'lore', 'Office Lore Quiz',
   'Six questions drawn from the nicknames, anecdotes, poems and battles of the Office. Most right answers wins.',
   'quiz', '{"count":6,"options":4,"scoring":"correct","fallback":"general","templates":["nick_who","nickstory_who","poem_author","battle_winner","count_poems","count_nicknames"]}'),
  ('wisdom_office_quiz', 'wisdom', 'Office Lore Quiz: Wisdom Edition',
   'Numbers and facts from the Office: Beer Sessions, beers, battles, nicknames. Six questions, most right wins.',
   'quiz', '{"count":6,"options":4,"scoring":"correct","fallback":"general","templates":["count_sessions","count_beers","count_nicknames","count_poems","battle_winner","beer_session","beer_best_rated"]}'),
  ('wisdom_closest_wins', 'wisdom', 'Closest Wins',
   'Three numeric questions about the Office. Type your best guess: the smallest total miss wins.',
   'quiz', '{"count":3,"scoring":"error","fallback":"general","templates":["num_counts"]}'),
  ('wisdom_know_thy_enemy', 'wisdom', 'Know Thy Enemy',
   'Five questions about your OPPONENT, from their ratings and nicknames to their poems. Your rival gets the mirror questions about you.',
   'quiz', '{"count":5,"options":4,"scoring":"correct","fallback":"general","templates":["enemy_best_beer","enemy_fav_style","enemy_rating_count","enemy_nickname","enemy_poems","enemy_sessions","enemy_perfect_pours"]}'),
  ('reflex_rapid_fire', 'reflex', 'Rapid Fire',
   '60 seconds on the clock. Answer as many quick questions as you can. Right answers count +1, wrong ones -1.',
   'timed', '{"count":40,"options":3,"duration_s":60,"scoring":"timed","short":true,"fallback":"beer","templates":["beer_style","higher_lower","nick_who","nick_real","beer_brewery"]}'),
  ('reflex_sudden_death', 'reflex', 'Sudden Death',
   'Questions keep coming until your first mistake. The longer streak takes the Trial. Made for the Final Trial.',
   'streak', '{"count":20,"options":4,"scoring":"streak","final_boost":true,"fallback":"beer","templates":["beer_style","beer_best_rated","nick_who","nick_of_person","poem_author","beer_brewery"]}')
on conflict (id) do update set
  school = excluded.school, title = excluded.title, description = excluded.description,
  resolution = excluded.resolution, public_config = excluded.public_config, is_active = true;

-- =================================================================
-- SECTION 9 — grants
-- =================================================================
do $$
declare
  f record;
begin
  -- every internal helper / template: no client role may call it
  for f in
    select p.oid::regprocedure as sig from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and (p.proname like '\_tq\_%' or p.proname like '\_throne\_%' or p.proname in
           ('_enemy_q', '_prepare_throne_trial', '_start_throne_trial', '_finalize_throne_run', '_resolve_quiz_trial',
            '_finalize_expired_runs', '_pick_final_throne_trial', '_finish_throne_trial', '_resolve_expired_throne_challenge'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

revoke all on function public.get_throne_run(uuid) from public, anon;
revoke all on function public.start_throne_run(uuid) from public, anon;
revoke all on function public.answer_throne_question(uuid, int, jsonb) from public, anon;
revoke all on function public.finish_throne_run(uuid) from public, anon;
grant execute on function public.get_throne_run(uuid) to authenticated;
grant execute on function public.start_throne_run(uuid) to authenticated;
grant execute on function public.answer_throne_question(uuid, int, jsonb) to authenticated;
grant execute on function public.finish_throne_run(uuid) to authenticated;
