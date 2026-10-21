-- =================================================================
-- OFFICE LORE — 🌍 REAL LIFE TRIALS
-- =================================================================
-- Physical, in-the-room challenges. The app GUIDES them (task, props, rules,
-- a big phone-on-the-table timer) but does not judge them: the Royal Judge
-- (0042) is the referee and names the winner.
--
-- A FIXED, CURATED POOL. Every Trial below is written by hand and reviewed
-- for safety. Nothing is generated freely and nothing is AI-written at
-- runtime; the only randomness is picking WHICH curated Trial, and which
-- curated option inside it (dance style, voice, quest ...).
--   SAFETY RULES BAKED INTO THE POOL
--   * nothing dangerous, nothing that can break or stain things
--   * nothing that involves driving, leaving the venue or running
--   * no alcohol task of any kind. The one drinking race, THE FASTEST PINT,
--     says in its title, description, rules and a red banner that it is for
--     WATER OR ALCOHOL-FREE BEER ONLY, in a small glass, with no chugging
--   * nothing humiliating or sexual, nothing illegal, no touching the
--     other player, no photos of people without their OK
--   * Real Life Trials only ever appear when "Allow Real Life Trials" was
--     switched on for the challenge (the school itself is gated, 0038)
--   * the Royal Judge can SKIP any Trial that is not possible or not
--     comfortable: no point is scored and a replacement Trial follows
--
-- FLOW (resolution 'reallife')
--   active           the task is shown (so the duelists can prepare). Each
--                    duelist presses READY on their own phone.
--   awaiting_judge   both are READY: GO! The timer helper runs on the phone.
--                    The Royal Judge watches and names the winner
--                    (defender / challenger / both were terrible / skip).
--   🎲 MYSTERY TRIAL the task is chosen by the server at the start and kept
--                    in a private table. It stays hidden until BOTH duelists
--                    press READY; only then is it revealed (and written to the
--                    Trial), and the client plays the reveal animation.
--   Deadlines (48h per step, lazy like everything else): a duelist who never
--   presses READY forfeits (nobody = coin flip); a Judge who never decides =
--   coin flip.
--
-- Additive + idempotent. Run once in the Supabase SQL Editor, after 0042.
-- =================================================================

-- =================================================================
-- SECTION 1 — schema
-- =================================================================
do $$
declare
  v_name text;
begin
  select conname into v_name from pg_constraint
    where conrelid = 'public.throne_trial_catalog'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%resolution%';
  if v_name is not null then execute format('alter table public.throne_trial_catalog drop constraint %I', v_name); end if;
end $$;

alter table public.throne_trial_catalog add constraint throne_trial_catalog_resolution_check
  check (resolution in ('roll', 'answer', 'judge', 'quiz', 'timed', 'streak', 'creative', 'reallife'));

-- the secret task of a Mystery Trial until both duelists are READY (PRIVATE)
create table if not exists public.throne_mystery_tasks (
  trial_id uuid primary key references public.throne_challenge_trials(id) on delete cascade,
  catalog_id text not null references public.throne_trial_catalog(id)
);
alter table public.throne_mystery_tasks enable row level security; -- deliberately NO policy

-- =================================================================
-- SECTION 2 — helpers
-- =================================================================
-- the random bits of a Real Life Trial (dance style, voice, quest, person ...),
-- drawn from the CURATED lists in the catalog row's public_config
create or replace function public._reallife_picks(p_cfg jsonb, p_trial_id uuid)
returns jsonb as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_picks jsonb := '[]'::jsonb;
  v_label text;
  v_pool jsonb;
  v_person text;
  v_lord text;
begin
  select * into t from public.throne_challenge_trials where id = p_trial_id;
  select * into c from public.throne_challenges where id = t.challenge_id;

  if p_cfg ? 'pools' then
    for v_label, v_pool in select key, value from jsonb_each(p_cfg->'pools') loop
      v_picks := v_picks || jsonb_build_object('label', v_label, 'value', v_pool->>(floor(random() * jsonb_array_length(v_pool))::int));
    end loop;
  end if;

  if p_cfg ? 'person_label' then
    -- a person from the Office Lore, never one of the people in this challenge
    select btrim(n.person_real_name) into v_person
    from public.nicknames n
    where btrim(n.person_real_name) <> ''
      and not exists (
        select 1 from public.profiles pr
        where pr.id in (c.challenger_user_id, c.defender_user_id, t.judge_user_id)
          and lower(split_part(btrim(pr.display_name), ' ', 1)) = lower(split_part(btrim(n.person_real_name), ' ', 1)))
    group by btrim(n.person_real_name)
    order by random() limit 1;
    if v_person is not null then
      v_picks := v_picks || jsonb_build_object('label', p_cfg->>'person_label', 'value', v_person);
    end if;
  end if;

  if coalesce((p_cfg->>'abt_lord')::boolean, false) then
    select pr.display_name into v_lord from public.abt_reigns r join public.profiles pr on pr.id = r.user_id where r.ended_at is null limit 1;
    if v_lord is not null then
      v_picks := v_picks || jsonb_build_object('label', 'Draw', 'value', v_lord || ', the Abt Lord');
    end if;
  end if;

  return v_picks;
end;
$$ language plpgsql volatile security definer set search_path = public;

create or replace function public._prepare_reallife_trial(p_trial_id uuid, p_cat public.throne_trial_catalog)
returns void as $$
declare
  t public.throne_challenge_trials;
  v_inner public.throne_trial_catalog;
begin
  select * into t from public.throne_challenge_trials where id = p_trial_id;

  if coalesce((p_cat.public_config->>'mystery')::boolean, false) then
    -- pick the hidden task now, keep it private until both are READY
    select c.* into v_inner from public.throne_trial_catalog c
      where c.is_active and c.school = 'real_life' and c.resolution = 'reallife'
        and not coalesce((c.public_config->>'mystery')::boolean, false)
        and c.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = t.challenge_id)
        and c.id not in (select m.catalog_id from public.throne_mystery_tasks m
                         join public.throne_challenge_trials x on x.id = m.trial_id where x.challenge_id = t.challenge_id)
      order by random() limit 1;
    if v_inner.id is null then
      raise exception 'No Real Life Trial left for the Mystery Trial';
    end if;
    insert into public.throne_mystery_tasks (trial_id, catalog_id) values (p_trial_id, v_inner.id);
    update public.throne_challenge_trials
      set public_config = public_config || jsonb_build_object('revealed', false)
      where id = p_trial_id;
  else
    update public.throne_challenge_trials
      set public_config = public_config || jsonb_build_object('picks', public._reallife_picks(p_cat.public_config, p_trial_id))
      where id = p_trial_id;
  end if;
end;
$$ language plpgsql volatile security definer set search_path = public;

-- eligibility: human-judged Trials need a member who is not a duelist; a
-- Mystery Trial's hidden task counts as used
create or replace function public._pick_catalog_trial(p_challenge_id uuid, p_school text)
returns public.throne_trial_catalog as $$
declare
  c public.throne_challenges;
  v_judge_exists boolean;
  v_school text := p_school;
  v_cat public.throne_trial_catalog;
begin
  select * into c from public.throne_challenges where id = p_challenge_id;

  select exists (
    select 1 from public.app_memberships m
    where m.app_id = 'officelore' and m.is_active = true
      and m.user_id not in (c.challenger_user_id, c.defender_user_id)
  ) into v_judge_exists;

  if v_school is not null then
    select t.* into v_cat from public.throne_trial_catalog t
      where t.is_active and t.school = v_school
        and (c.allow_real_life or t.school <> 'real_life')
        and (t.resolution not in ('judge', 'creative', 'reallife') or v_judge_exists)
        and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
        and t.id not in (select m.catalog_id from public.throne_mystery_tasks m
                         join public.throne_challenge_trials x on x.id = m.trial_id where x.challenge_id = p_challenge_id)
      order by random() limit 1;
    if v_cat.id is not null then
      return v_cat;
    end if;
  end if;

  select s.school into v_school from (
    select distinct t.school from public.throne_trial_catalog t
      where t.is_active
        and (c.allow_real_life or t.school <> 'real_life')
        and (t.resolution not in ('judge', 'creative', 'reallife') or v_judge_exists)
        and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
        and t.id not in (select m.catalog_id from public.throne_mystery_tasks m
                         join public.throne_challenge_trials x on x.id = m.trial_id where x.challenge_id = p_challenge_id)
  ) s order by random() limit 1;

  if v_school is null then
    raise exception 'No Trials available for this Throne Challenge';
  end if;

  select t.* into v_cat from public.throne_trial_catalog t
    where t.is_active and t.school = v_school
      and (c.allow_real_life or t.school <> 'real_life')
      and (t.resolution not in ('judge', 'creative', 'reallife') or v_judge_exists)
      and t.id not in (select catalog_id from public.throne_challenge_trials where challenge_id = p_challenge_id)
      and t.id not in (select m.catalog_id from public.throne_mystery_tasks m
                       join public.throne_challenge_trials x on x.id = m.trial_id where x.challenge_id = p_challenge_id)
    order by random() limit 1;
  return v_cat;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function public._start_throne_trial(p_challenge_id uuid, p_cat public.throne_trial_catalog, p_picker uuid)
returns uuid as $$
declare
  v_no int;
  v_attempt int;
  v_id uuid;
  v_status text;
  v_judge uuid;
begin
  select count(*) + 1 into v_no from public.throne_challenge_trials where challenge_id = p_challenge_id and status <> 'voided';
  select count(*) + 1 into v_attempt from public.throne_challenge_trials where challenge_id = p_challenge_id and trial_no = v_no;
  v_status := case when p_cat.resolution = 'judge' then 'awaiting_judge' else 'active' end;
  v_judge := case when p_cat.resolution in ('judge', 'creative', 'reallife') then public._pick_judge(p_challenge_id) end;

  insert into public.throne_challenge_trials
    (challenge_id, trial_no, attempt, picker_user_id, school, catalog_id, title, description, resolution, public_config, status, judge_user_id)
  values
    (p_challenge_id, v_no, v_attempt, p_picker, p_cat.school, p_cat.id, p_cat.title, p_cat.description, p_cat.resolution, p_cat.public_config, v_status, v_judge)
  returning id into v_id;

  if p_cat.resolution in ('quiz', 'timed', 'streak') then
    perform public._prepare_throne_trial(v_id, p_cat);
  elsif p_cat.resolution = 'creative' then
    perform public._prepare_creative_trial(v_id, p_cat);
  elsif p_cat.resolution = 'reallife' then
    perform public._prepare_reallife_trial(v_id, p_cat);
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
-- SECTION 3 — READY
-- =================================================================
create or replace function public.ready_throne_trial(p_trial_id uuid)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_inner public.throne_trial_catalog;
  v_cfg jsonb;
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.id is null or t.resolution <> 'reallife' or t.status <> 'active' then
    raise exception 'This Trial is not waiting for READY';
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() not in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'Only the two duelists can be READY';
  end if;

  if auth.uid() = c.challenger_user_id then
    update public.throne_challenge_trials set challenger_submitted = true where id = t.id;
  else
    update public.throne_challenge_trials set defender_submitted = true where id = t.id;
  end if;
  select * into t from public.throne_challenge_trials where id = t.id;

  if t.challenger_submitted and t.defender_submitted then
    v_cfg := t.public_config;
    if coalesce((v_cfg->>'mystery')::boolean, false) and not coalesce((v_cfg->>'revealed')::boolean, false) then
      -- REVEAL: the hidden task becomes the Trial
      select ct.* into v_inner from public.throne_mystery_tasks m join public.throne_trial_catalog ct on ct.id = m.catalog_id where m.trial_id = t.id;
      update public.throne_challenge_trials
        set title = v_inner.title, description = v_inner.description,
            public_config = v_inner.public_config
              || jsonb_build_object('mystery', true, 'revealed', true, 'picks', public._reallife_picks(v_inner.public_config, t.id), 'go_at', now())
        where id = t.id;
    else
      update public.throne_challenge_trials
        set public_config = public_config || jsonb_build_object('go_at', now())
        where id = t.id;
    end if;
    update public.throne_challenge_trials set status = 'awaiting_judge' where id = t.id;
    update public.throne_challenges set status = 'awaiting_judge', step_deadline = now() + interval '48 hours' where id = c.id;
  end if;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 4 — the Royal Judge's verdict (0042's, now also for Real Life)
-- =================================================================
--   creative Trials (anonymous):          'A' | 'B' | 'both_terrible'
--   judge / Real Life Trials (named):     'challenger' | 'defender' | 'both_terrible'
--   Real Life / judge Trials only:        'skip'  (not possible or not comfortable here)
-- 'both_terrible' and 'skip' score no point; the Trial is voided and replaced.
create or replace function public.judge_throne_verdict(p_trial_id uuid, p_verdict text)
returns void as $$
declare
  t public.throne_challenge_trials;
  c public.throne_challenges;
  v_cat public.throne_trial_catalog;
  v_winner uuid;
  v_entries jsonb;
  v_void boolean := p_verdict in ('both_terrible', 'skip');
begin
  if not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  perform pg_advisory_xact_lock(918273645);
  perform public._resolve_expired_throne_challenge();

  select * into t from public.throne_challenge_trials where id = p_trial_id for update;
  if t.id is null or t.status <> 'awaiting_judge' or t.resolution not in ('judge', 'creative', 'reallife') then
    raise exception 'This Trial is not waiting for the Royal Judge';
  end if;
  select * into c from public.throne_challenges where id = t.challenge_id;
  if auth.uid() in (c.challenger_user_id, c.defender_user_id) then
    raise exception 'A duelist cannot judge their own Trial';
  end if;
  if t.judge_user_id is not null and t.judge_user_id <> auth.uid() then
    raise exception 'You are not the Royal Judge of this Trial';
  end if;

  if v_void then
    if p_verdict = 'skip' and t.resolution = 'creative' then raise exception 'Unknown verdict'; end if;
  elsif t.resolution = 'creative' and p_verdict in ('A', 'B') then
    select user_id into v_winner from public.throne_trial_submissions where trial_id = t.id and slot = p_verdict;
  elsif t.resolution in ('judge', 'reallife') and p_verdict = 'challenger' then
    v_winner := c.challenger_user_id;
  elsif t.resolution in ('judge', 'reallife') and p_verdict = 'defender' then
    v_winner := c.defender_user_id;
  else
    raise exception 'Unknown verdict';
  end if;
  if not v_void and v_winner is null then
    raise exception 'Unknown verdict';
  end if;

  v_entries := case when t.resolution = 'creative' then public._throne_creative_reveal(t.id) else null end;

  if not v_void then
    update public.throne_challenge_trials
      set judge_user_id = auth.uid(),
          reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('judge', auth.uid(), 'verdict', p_verdict)
                   || case when v_entries is not null then jsonb_build_object('entries', v_entries) else '{}'::jsonb end
      where id = t.id;
    perform public._finish_throne_trial(t.id, v_winner);
    return;
  end if;

  -- no point scored: void it and play a replacement Trial
  begin
    update public.throne_challenge_trials
      set status = 'voided', completed_at = now(), judge_user_id = auth.uid(),
          reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('judge', auth.uid(), 'verdict', p_verdict, 'voided', true, 'skipped', p_verdict = 'skip')
                   || case when v_entries is not null then jsonb_build_object('entries', v_entries) else '{}'::jsonb end
      where id = t.id;
    v_cat := public._pick_catalog_trial(c.id, t.school);
    perform public._start_throne_trial(c.id, v_cat, t.picker_user_id);
  exception when raise_exception then
    -- no replacement Trial left: the throne decides by coin flip, openly
    v_winner := case when random() < 0.5 then c.challenger_user_id else c.defender_user_id end;
    update public.throne_challenge_trials
      set status = 'awaiting_judge', completed_at = null,
          reveal = coalesce(reveal, '{}'::jsonb) || jsonb_build_object('judge', auth.uid(), 'verdict', p_verdict, 'coin_flip', true)
                   || case when v_entries is not null then jsonb_build_object('entries', v_entries) else '{}'::jsonb end
      where id = t.id;
    perform public._finish_throne_trial(t.id, v_winner);
  end;
end;
$$ language plpgsql security definer set search_path = public;

-- =================================================================
-- SECTION 5 — the curated Real Life pool
-- =================================================================
-- the 0038 placeholders are retired (arm wrestling is not a safe default)
update public.throne_trial_catalog set is_active = false where id in ('real_bottle_flip', 'real_arm_wrestle');

-- public_config keys the client understands:
--   icon, props, rules[], decide, format, timer_s, timer_mode (turns | shared | stopwatch),
--   timer_label, pools{label:[...]}, person_label, abt_lord, drink_safe, mystery
insert into public.throne_trial_catalog (id, school, title, description, resolution, public_config) values
  ('real_royal_waltz', 'real_life', 'The Royal Waltz',
   '30 seconds each to show your finest waltz. Grace beats speed.', 'reallife',
   $j${"icon":"💃","props":"A little clear floor space","timer_s":30,"timer_mode":"turns","timer_label":"Waltz",
       "rules":["One duelist at a time, 30 seconds each.","Waltz solo or with an imaginary partner. No touching the other duelist.","Mind the furniture, the glasses and your neighbours."],
       "decide":"Grace, rhythm and royal bearing."}$j$::jsonb),
  ('real_fastest_pint', 'real_life', 'The Fastest Pint (alcohol-free)',
   'A race to finish a small glass of WATER or ALCOHOL-FREE beer. Never alcohol. This is not a drinking contest.', 'reallife',
   $j${"icon":"🥤","drink_safe":true,"props":"Two small glasses (25 cl at most) of WATER or ALCOHOL-FREE beer","timer_mode":"stopwatch","timer_label":"Race",
       "rules":["WATER OR ALCOHOL-FREE BEER ONLY. No alcohol, ever, in this Trial.","Small glass, 25 cl at most. Drink steadily: no gulping contest.","Stop at once if anyone coughs, chokes or feels unwell.","Ready, set, drink! The Royal Judge calls who finished first."],
       "decide":"First to put down an empty glass."}$j$::jsonb),
  ('real_coin_to_glass', 'real_life', 'Coin to Glass',
   'Best of 5: drop a coin into an EMPTY glass or cup.', 'reallife',
   $j${"icon":"🎯","format":"Best of 5","props":"A coin each and an empty plastic cup or sturdy glass","timer_mode":"none",
       "rules":["Empty cup on a stable table. No drinks involved.","Five attempts each, taking turns, from a fixed distance you agree on.","Most coins in the cup wins; a tie is settled by one sudden-death attempt each."],
       "decide":"Most coins in the cup after five attempts."}$j$::jsonb),
  ('real_flip_cup', 'real_life', 'Royal Flip Cup',
   'Flip an EMPTY plastic cup so it lands upside down. Best of 3, or first clean flip.', 'reallife',
   $j${"icon":"🥤","format":"Best of 3 or first clean flip","props":"An empty plastic cup each","timer_mode":"none",
       "rules":["Empty plastic cups only. There are NO drinks in this game.","Set the cup over the table edge and flick the base to flip it.","Agree before you start: best of 3, or first clean flip wins."],
       "decide":"Most clean flips, or the first one."}$j$::jsonb),
  ('real_kings_toss', 'real_life', 'The King''s Toss',
   'Bounce a coin off the table into a cup.', 'reallife',
   $j${"icon":"🪙","props":"A coin each, an empty cup, a sturdy table","timer_mode":"none","format":"3 tosses each",
       "rules":["Empty cup, no drinks.","Bounce the coin once off the table so that it lands in the cup.","Three tosses each, taking turns. Most successful tosses wins.","Toss along the table, never towards people."],
       "decide":"Most coins in the cup."}$j$::jsonb),
  ('real_tower', 'real_life', 'The Tower',
   '60 seconds to build the tallest free-standing tower of coasters.', 'reallife',
   $j${"icon":"🧻","props":"A pile of coasters (or other flat, light objects) each","timer_s":60,"timer_mode":"shared","timer_label":"Build",
       "rules":["Coasters or other flat, light objects only.","Free-standing: no leaning on anything, and hands off when time is up.","The tower must still stand when the Royal Judge looks."],
       "decide":"The tallest tower still standing."}$j$::jsonb),
  ('real_coaster_flip', 'real_life', 'Coaster Flip',
   'Flip and catch coasters. One more every round. The first failure loses.', 'reallife',
   $j${"icon":"🍻","props":"A stack of coasters each","timer_mode":"none",
       "rules":["Round 1: flick one coaster off the table edge and catch it.","Each round add one more coaster to the stack you flip.","The first to drop the coaster, or the stack, loses the Trial.","Keep the flips low and over the table."],
       "decide":"Last one still catching."}$j$::jsonb),
  ('real_draw_enemy', 'real_life', 'Draw Thy Enemy',
   '60 seconds. Draw your opponent.', 'reallife',
   $j${"icon":"🎨","props":"Pen and paper (or a drawing app)","timer_s":60,"timer_mode":"shared","timer_label":"Draw",
       "rules":["Draw your opponent in 60 seconds.","Funny is good, cruel is not. Be kind to the face and to the ego.","Show both drawings to the Royal Judge at the same time."],
       "decide":"The best (funniest) portrait."}$j$::jsonb),
  ('real_draw_abt', 'real_life', 'Draw the Abt',
   'Draw the current Abt Lord with your eyes closed.', 'reallife',
   $j${"icon":"👑","abt_lord":true,"props":"Pen and paper","timer_s":45,"timer_mode":"shared","timer_label":"Draw",
       "rules":["Close your eyes (or cover them with your free hand) and draw the subject in 45 seconds.","Stay seated and put nothing over your eyes that you cannot take off at once.","No peeking! The Royal Judge watches."],
       "decide":"The most majestic (or most hilarious) likeness."}$j$::jsonb),
  ('real_royal_statue', 'real_life', 'Royal Statue',
   'Stay as still as a statue for as long as you can. The Royal Judge tries to make you laugh.', 'reallife',
   $j${"icon":"🗿","props":"Nothing","timer_mode":"stopwatch","timer_label":"Statue",
       "rules":["Freeze like a statue. First to move or laugh is out.","The Royal Judge may pull faces, make sounds and tell clean jokes.","No touching, tickling or props near faces."],
       "decide":"The statue that lasts the longest."}$j$::jsonb),
  ('real_dont_laugh', 'real_life', 'Don''t Laugh',
   'The first one to laugh loses.', 'reallife',
   $j${"icon":"😐","props":"Nothing","timer_mode":"stopwatch","timer_label":"Straight faces",
       "rules":["Face each other with a straight face. The first to laugh or smile loses.","The Royal Judge or the other duelist may make faces, but no touching or tickling.","Clean jokes only."],
       "decide":"The last straight face."}$j$::jsonb),
  ('real_staring_contest', 'real_life', 'Staring Contest',
   'The classic. First to blink or look away loses.', 'reallife',
   $j${"icon":"👁️","props":"Nothing","timer_mode":"stopwatch","timer_label":"Stare",
       "rules":["Look each other in the eyes. First to blink or look away loses.","Stop if your eyes hurt; the Royal Judge will call it."],
       "decide":"The last one staring."}$j$::jsonb),
  ('real_dance_abt', 'real_life', 'Dance of the Abt',
   'A random dance style. 30 seconds each. Commit.', 'reallife',
   $j${"icon":"🕺","props":"A little clear floor space","timer_s":30,"timer_mode":"turns","timer_label":"Dance",
       "pools":{"Style":["Waltz","Disco","Robot","Slow Motion","Irish Dance","Interpretive Dance"]},
       "rules":["The app picks the dance style for both duelists.","One at a time, 30 seconds each.","Keep it safe: no jumps, no lifts, no touching the other duelist.","Mind the furniture and the glasses."],
       "decide":"The best dance in this style."}$j$::jsonb),
  ('real_karaoke', 'real_life', 'Royal Karaoke',
   '30 seconds of song each.', 'reallife',
   $j${"icon":"🎤","props":"A song you know (a hairbrush microphone is welcome)","timer_s":30,"timer_mode":"turns","timer_label":"Sing",
       "rules":["Any song, friendly lyrics only. 30 seconds each, one at a time.","Everyone, including the Royal Judge, must listen with respect."],
       "decide":"The most royal performance."}$j$::jsonb),
  ('real_impersonation', 'real_life', 'Impersonation Trial',
   'Impersonate a person from the Office Lore. Kind, not cruel.', 'reallife',
   $j${"icon":"🎭","props":"Nothing","timer_s":30,"timer_mode":"turns","timer_label":"Act","person_label":"Impersonate",
       "rules":["Impersonate the person shown: how they talk, move or laugh. 30 seconds each.","Keep it kind: a mannerism or a catchphrase, never a flaw, their looks or anything private.","Only people from the Office Lore are used."],
       "decide":"The best performance."}$j$::jsonb),
  ('real_accent_battle', 'real_life', 'Accent Battle',
   'The same absurd line, in the same funny voice.', 'reallife',
   $j${"icon":"🗣️","props":"Nothing","timer_s":30,"timer_mode":"turns","timer_label":"Perform",
       "pools":{"Voice":["a pirate captain","a very posh butler","a robot running out of battery","a medieval king","a dramatic news anchor","a nature documentary narrator","an opera singer","a cowboy"],
                "Line":["The biscuit tin has been empty since Tuesday and nobody will speak of it.","I would like to speak to whoever moved my stapler.","The printer and I have an understanding.","Today we gather to mourn the last beer in the fridge."]},
       "rules":["Both perform the same line in the same voice, one at a time, 30 seconds.","The voice is always a character, never a real nationality or group of people."],
       "decide":"The best performance of the line."}$j$::jsonb),
  ('real_royal_speech_live', 'real_life', 'Royal Speech: Live',
   '30 seconds of royal improvisation on a topic you get on the spot.', 'reallife',
   $j${"icon":"📢","props":"Nothing","timer_s":30,"timer_mode":"turns","timer_label":"Speak",
       "pools":{"Topic":["Why the Taproom needs a moat.","Why Mondays are abolished by royal decree.","Why the last biscuit belongs to the crown.","Why my chair is the true throne.","Why every meeting should end with a toast."]},
       "rules":["Improvise a speech on the topic, 30 seconds each, one at a time.","No preparation, no notes."],
       "decide":"The most convincing (or most entertaining) speech."}$j$::jsonb),
  ('real_five_seconds', 'real_life', 'Five Seconds',
   'Name three valid answers within 5 seconds.', 'reallife',
   $j${"icon":"🧠","props":"Nothing","timer_s":5,"timer_mode":"turns","timer_label":"5 seconds",
       "pools":{"Round 1":["Three beer brands","Three things in a kitchen","Three Belgian cities"],
                "Round 2":["Three things you find in a pub","Three animals with four legs","Three colours of the rainbow"],
                "Round 3":["Three board games","Three types of cheese","Three things that are round"]},
       "rules":["Three rounds. In each round the category is shown; the duelist whose turn it is has 5 seconds to name three valid answers.","Alternate who starts each round.","The Royal Judge decides what counts as valid."],
       "decide":"Most successful rounds."}$j$::jsonb),
  ('real_hum_tune', 'real_life', 'Hum That Tune',
   'One hums, the other guesses. Then swap.', 'reallife',
   $j${"icon":"🎵","props":"Songs in your head","timer_s":30,"timer_mode":"turns","timer_label":"Hum",
       "pools":{"Category":["a famous movie theme","a children's song","a pop classic","a Christmas song","a cartoon theme","a Disney song"]},
       "rules":["The hummer picks a song from the category and hums it for 30 seconds. No words!","The other duelist guesses. Then swap roles.","The Royal Judge keeps score of the correct guesses."],
       "decide":"Most songs guessed."}$j$::jsonb),
  ('real_fashion', 'real_life', 'The Fashion Trial',
   '2 minutes to create the most majestic Abt outfit from what is around you.', 'reallife',
   $j${"icon":"🧦","props":"Whatever is around you","timer_s":120,"timer_mode":"shared","timer_label":"Dress",
       "rules":["Create the most majestic Abt outfit in 2 minutes with your own belongings or things you have permission to use.","Nothing that can stain, tear or hurt. Keep it dignified.","Model it for the Royal Judge when the time is up."],
       "decide":"The most majestic outfit."}$j$::jsonb),
  ('real_paper_toss', 'real_life', 'Paper Toss',
   'Scrunch up a sheet of paper and sink it. Best of 5.', 'reallife',
   $j${"icon":"🏹","format":"Best of 5","props":"Scrap paper and a bin or cup as target","timer_mode":"none",
       "rules":["Aim at the bin or cup, never at people.","Five throws each from the same spot, taking turns.","Most hits wins; a tie is settled by one sudden-death throw each."],
       "decide":"Most hits in five throws."}$j$::jsonb),
  ('real_air_force', 'real_life', 'Royal Air Force',
   'Build a paper plane. The furthest valid flight wins.', 'reallife',
   $j${"icon":"✈️","props":"One sheet of paper each","timer_s":60,"timer_mode":"shared","timer_label":"Build",
       "rules":["60 seconds to build a paper plane.","Throw along a clear path, away from people.","Each duelist gets one flight; the Royal Judge measures."],
       "decide":"The furthest valid flight."}$j$::jsonb),
  ('real_balance_power', 'real_life', 'Balance of Power',
   'Balance a safe little object. The longest time wins.', 'reallife',
   $j${"icon":"⚖️","props":"A coaster, spoon or pen each","timer_mode":"stopwatch","timer_label":"Balance",
       "rules":["Balance the object on a finger, the back of your hand or your chin while seated or standing still.","Nothing sharp, hot or fragile.","The clock stops when the object falls."],
       "decide":"The longest balance."}$j$::jsonb),
  ('real_quest', 'real_life', 'The Quest',
   'A simple, safe fetch quest. First back wins.', 'reallife',
   $j${"icon":"🏃","props":"The venue around you","timer_mode":"stopwatch","timer_label":"Quest",
       "pools":{"Quest":["Bring something yellow.","Bring something that smells nice.","Bring the roundest object you can find.","Bring the most boring object in the room.","Bring something that starts with the letter B.","Bring the smallest useful thing you can find."]},
       "rules":["Stay inside the venue. WALK, don't run.","Take only what is yours or what you have permission to take.","First back with a valid item wins; the Royal Judge decides what is valid."],
       "decide":"First back with a valid item."}$j$::jsonb),
  ('real_photo_quest', 'real_life', 'Photo Quest',
   'The most majestic photo wins.', 'reallife',
   $j${"icon":"📸","props":"Your phone's camera","timer_s":120,"timer_mode":"shared","timer_label":"Shoot",
       "pools":{"Quest":["Take the most majestic photo with a plant.","Take a heroic portrait of a chair.","Take the most dramatic photo of a coaster.","Take a royal portrait of a glass.","Take a photo that looks like a movie poster, using only objects."]},
       "rules":["2 minutes. Photograph objects, plants or yourself only: no photos of other people without their OK.","Stay inside the venue.","The photos stay on your phone; show them to the Royal Judge."],
       "decide":"The most majestic photo."}$j$::jsonb),
  ('real_mystery', 'real_life', 'Mystery Trial',
   'The task is hidden until BOTH duelists press READY.', 'reallife',
   $j${"icon":"🎲","mystery":true,"props":"???","rules":["Nobody knows the task.","Both duelists press READY to reveal it.","Then the Royal Judge watches and decides."],"decide":"???"}$j$::jsonb)
on conflict (id) do update set
  school = excluded.school, title = excluded.title, description = excluded.description,
  resolution = excluded.resolution, public_config = excluded.public_config, is_active = true;

-- =================================================================
-- SECTION 6 — grants
-- =================================================================
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('_reallife_picks', '_prepare_reallife_trial', '_pick_catalog_trial', '_start_throne_trial')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

revoke all on function public.ready_throne_trial(uuid) from public, anon;
revoke all on function public.judge_throne_verdict(uuid, text) from public, anon;
grant execute on function public.ready_throne_trial(uuid) to authenticated;
grant execute on function public.judge_throne_verdict(uuid, text) to authenticated;
