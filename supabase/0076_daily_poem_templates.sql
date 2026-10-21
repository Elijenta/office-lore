-- =================================================================
-- 0076 — Daily poem: opdrachten uit een tabel i.p.v. hardcoded
--
-- Tot nu toe zaten de 9 categorieën x 3 sjablonen vast in
-- get_or_create_daily_challenge(). Nu staan ze in
-- public.daily_poem_templates: nieuwe opdracht = nieuwe rij, geen code.
-- Seed = de 27 bestaande + 4 extra per bestaande categorie + 5 nieuwe
-- categorieën (spooky, detective, fairytale, scifi, sports) met 6 elk.
-- %s in een sjabloon wordt het onderwerp (nickname of lid).
--
-- Additief + idempotent. Bestaande daily_poetry_challenges-rijen blijven
-- ongewijzigd. Draai 1x in de Supabase SQL editor (na 0075).
-- =================================================================

create table if not exists public.daily_poem_templates (
  id         uuid primary key default gen_random_uuid(),
  category   text not null check (length(category) between 2 and 40),
  template   text not null check (template like '%\%s%' and length(template) <= 300),
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  unique (category, template)
);

alter table public.daily_poem_templates enable row level security;
drop policy if exists "Daily poem templates: read" on public.daily_poem_templates;
create policy "Daily poem templates: read" on public.daily_poem_templates
  for select to authenticated using (public.is_app_member('officelore'));
-- geen insert/update/delete-policy: beheer via SQL editor

-- de oude vaste categorielijst mag nieuwe categorieën niet blokkeren
alter table public.daily_poetry_challenges drop constraint if exists daily_poetry_challenges_category_check;

insert into public.daily_poem_templates (category, template) values
  -- romantic
  ('romantic','Write a romantic poem about %s as if they were the love of your life.'),
  ('romantic','Write a love poem describing an unexpected office encounter with %s.'),
  ('romantic','Write a sonnet about someone hopelessly falling for %s.'),
  ('romantic','Write a love letter in verse to %s, delivered by carrier pigeon.'),
  ('romantic','Write a poem about a first date with %s at the office vending machine.'),
  ('romantic','Write a poem where %s and a half-eaten pizza share a forbidden love.'),
  ('romantic','Write a breakup poem in which %s says "it''s not you, it''s the meeting schedule".'),
  -- tragic
  ('tragic','Write a tragic poem about the day %s lost everything.'),
  ('tragic','Write a tragic poem mourning %s''s greatest defeat.'),
  ('tragic','Write a eulogy-style poem for %s''s fallen dignity.'),
  ('tragic','Write a poem about %s watching their last biscuit roll under the fridge.'),
  ('tragic','Write a tragic ballad of %s and the unsaved document.'),
  ('tragic','Write a farewell poem for %s as they leave the office forever (just for the weekend).'),
  ('tragic','Write a heartbreaking poem about %s and the meeting that could have been an e-mail.'),
  -- office_nonsense
  ('office_nonsense','Write an absurd office poem starring %s in an epic printer battle.'),
  ('office_nonsense','Write about %s discovering a mysterious smell in the office kitchen.'),
  ('office_nonsense','Write a poem about %s becoming an office legend for all the wrong reasons.'),
  ('office_nonsense','Write a poem about %s accidentally replying all.'),
  ('office_nonsense','Write about %s and the mystery of the disappearing lunch from the fridge.'),
  ('office_nonsense','Write a poem about %s trapped in a never-ending video call.'),
  ('office_nonsense','Write an ode to %s''s unreasonably loud keyboard.'),
  -- beer_inspired
  ('beer_inspired','Write an ode to %s discovering the perfect beer.'),
  ('beer_inspired','Write a tragic poem about %s finding the beer fridge empty.'),
  ('beer_inspired','Write a medieval poem about %s and the Abt Lord''s throne.'),
  ('beer_inspired','Write a drinking song about %s and the first sip after a long week.'),
  ('beer_inspired','Write a poem about %s as a sommelier who only reviews tap water.'),
  ('beer_inspired','Write a toast in verse for %s, raised with a very full glass.'),
  ('beer_inspired','Write an epic poem about %s on a quest for the legendary 10/10 beer.'),
  -- absolute_nonsense
  ('absolute_nonsense','Write a poem about %s being elected Supreme Leader by the office printer.'),
  ('absolute_nonsense','Write about %s slowly turning into a sentient stapler.'),
  ('absolute_nonsense','Write an absurd poem about %s versus a rogue PowerPoint presentation.'),
  ('absolute_nonsense','Write a poem about %s discovering that all the chairs are secretly alive.'),
  ('absolute_nonsense','Write about %s hosting a talk show for houseplants.'),
  ('absolute_nonsense','Write a poem in which %s negotiates peace between the coffee machine and the kettle.'),
  ('absolute_nonsense','Write about %s waking up as a rubber duck in a corporate aquarium.'),
  -- dramatic
  ('dramatic','Describe %s losing Wi-Fi as if civilization itself has collapsed.'),
  ('dramatic','Turn %s''s minor office inconvenience into a Shakespearean tragedy.'),
  ('dramatic','Write an epic battle poem starring %s against a broken coffee machine.'),
  ('dramatic','Write a dramatic monologue for %s when the last slice of cake is gone.'),
  ('dramatic','Describe %s walking into the office on a Monday as a hero''s return from war.'),
  ('dramatic','Write a poem narrating %s''s lunch break like a nature documentary.'),
  ('dramatic','Write an opera-style poem about %s and a jammed stapler.'),
  -- abt_dynasty
  ('abt_dynasty','Write a medieval prophecy about %s attempting to seize the Abt throne.'),
  ('abt_dynasty','Turn %s into a legendary knight serving the Abt Lord.'),
  ('abt_dynasty','Write a coronation poem imagining %s as the next Abt Lord.'),
  ('abt_dynasty','Write a royal decree in verse, signed by %s, ruling over the taproom.'),
  ('abt_dynasty','Write a ballad of the court jester %s who tells the Abt Lord the truth.'),
  ('abt_dynasty','Write a poem about %s plotting a quiet rebellion against the Abt Lord.'),
  ('abt_dynasty','Write a chronicle entry about the glorious reign of %s, the Beer-Blessed.'),
  -- deep_thoughts
  ('deep_thoughts','Write a philosophical poem about %s contemplating the meaning of a Monday.'),
  ('deep_thoughts','Write a deep, reflective poem about %s staring at a spreadsheet.'),
  ('deep_thoughts','Write an existential poem from %s''s perspective at 4:59 PM.'),
  ('deep_thoughts','Write a poem about %s wondering why the printer only jams when it matters.'),
  ('deep_thoughts','Write a meditation by %s on whether a hot drink ever stays hot long enough.'),
  ('deep_thoughts','Write a haiku-style poem about %s and the elevator that never comes.'),
  ('deep_thoughts','Write a poem about %s realising that "quick question" is never quick.'),
  -- wholesome
  ('wholesome','Write a wholesome poem about %s making everyone''s day a little better.'),
  ('wholesome','Write a heartwarming poem about %s sharing their lunch.'),
  ('wholesome','Write a sweet poem about %s remembering everyone''s birthday.'),
  ('wholesome','Write a cozy poem about %s bringing coffee to the whole team.'),
  ('wholesome','Write a poem thanking %s for always laughing at our bad jokes.'),
  ('wholesome','Write a gentle lullaby for %s after a very long week.'),
  ('wholesome','Write a poem about %s helping a colleague with a tricky problem without being asked.'),
  -- spooky (nieuw)
  ('spooky','Write a ghost story in verse about %s alone in the office at midnight.'),
  ('spooky','Write a spooky poem about %s hearing the printer whisper their name.'),
  ('spooky','Write a haunted-house poem where %s is the friendly ghost of the break room.'),
  ('spooky','Write a chilling poem about %s and the elevator that stops on floor 13.'),
  ('spooky','Write a poem about %s discovering that the office cat is a vampire.'),
  ('spooky','Write a gothic poem about %s and the cursed coffee mug.'),
  -- detective (nieuw)
  ('detective','Write a noir detective poem in which %s investigates the stolen lunch.'),
  ('detective','Write a poem where %s is the detective hunting the person who always leaves the printer empty.'),
  ('detective','Write a crime-scene poem: %s found a single crumb and nothing will be the same.'),
  ('detective','Write a poem about %s interrogating a suspicious potted plant.'),
  ('detective','Write a mystery in verse: who drank %s''s last beer?'),
  ('detective','Write a courtroom poem in which %s defends the right to a second coffee.'),
  -- fairytale (nieuw)
  ('fairytale','Write a fairy tale in verse about %s and the dragon who guards the beer cellar.'),
  ('fairytale','Write a poem about %s as a prince(ss) who must kiss the right frog to get Wi-Fi back.'),
  ('fairytale','Write a bedtime story in verse about %s lost in the Enchanted Forest of Meetings.'),
  ('fairytale','Write a poem about %s and three wishes granted by a genie in the copy room.'),
  ('fairytale','Write a poem about %s, a wizard whose only spell is "reply later".'),
  ('fairytale','Write a ballad of %s the brave, who slayed the dragon of overdue e-mails.'),
  -- scifi (nieuw)
  ('scifi','Write a space-opera poem about %s commanding the starship Break Room.'),
  ('scifi','Write a poem about %s being abducted by aliens who only want the office snacks.'),
  ('scifi','Write a poem about %s discovering that the coffee machine is an AI plotting world domination.'),
  ('scifi','Write a poem from %s''s perspective as the last human in a robot-run office.'),
  ('scifi','Write a time-travel poem in which %s goes back to avoid one single meeting.'),
  ('scifi','Write a cyberpunk poem about %s hacking the vending machine.'),
  -- sports (nieuw)
  ('sports','Write a sports-commentary poem about %s in the final of the office chair race.'),
  ('sports','Write a poem about %s winning gold in synchronised coffee carrying.'),
  ('sports','Write a play-by-play poem of %s sprinting to the kitchen when lunch is announced.'),
  ('sports','Write a locker-room speech in verse by %s before the big quarterly review.'),
  ('sports','Write a poem about %s as a trainer who coaches the printer to better performance.'),
  ('sports','Write a marathon poem about %s walking to the meeting room at the other end of the building.')
on conflict (category, template) do nothing;

-- ---- get_or_create_daily_challenge(): kiest uit de tabel ----------------
-- Zelfde seeds, zelfde subject-logica, zelfde race-veiligheid als 0015.
create or replace function public.get_or_create_daily_challenge()
returns public.daily_poetry_challenges as $$
declare
  v_today date := current_date;
  v_row public.daily_poetry_challenges;
  v_subject_type text;
  v_nickname_id uuid;
  v_user_id uuid;
  v_subject_text text;
  v_category text;
  v_template text;
  v_prompt_text text;
  v_nickname_count int;
  v_user_count int;
  v_category_count int;
  v_template_count int;
  v_subject_seed bigint := abs(hashtext('daily-challenge-subject:' || v_today::text));
  v_category_seed bigint := abs(hashtext('daily-challenge-category:' || v_today::text));
  v_template_seed bigint := abs(hashtext('daily-challenge-template:' || v_today::text));
begin
  perform pg_advisory_xact_lock(hashtext('daily_poetry_challenge:' || v_today::text));

  select * into v_row from public.daily_poetry_challenges where challenge_date = v_today;
  if found then
    return v_row;
  end if;

  select count(*) into v_nickname_count from public.nicknames;
  select count(*) into v_user_count
  from public.profiles p
  join public.app_memberships m on m.user_id = p.id and m.app_id = 'officelore' and m.is_active = true;

  if v_nickname_count > 0 and (v_user_count = 0 or v_subject_seed % 2 = 0) then
    v_subject_type := 'nickname';
    select id, nickname into v_nickname_id, v_subject_text
      from public.nicknames order by id offset (v_subject_seed % v_nickname_count) limit 1;
  else
    v_subject_type := 'user';
    select id, display_name into v_user_id, v_subject_text
      from (
        select p.id, p.display_name
        from public.profiles p
        join public.app_memberships m on m.user_id = p.id and m.app_id = 'officelore' and m.is_active = true
      ) t
      order by id offset (v_subject_seed % greatest(v_user_count, 1)) limit 1;
  end if;

  -- categorie: willekeurig uit de actieve categorieën in de tabel
  select count(distinct category) into v_category_count
    from public.daily_poem_templates where is_active;
  if v_category_count > 0 then
    select category into v_category from (
      select distinct category from public.daily_poem_templates where is_active
    ) c order by category offset (v_category_seed % v_category_count) limit 1;

    select count(*) into v_template_count
      from public.daily_poem_templates where is_active and category = v_category;
    select template into v_template
      from public.daily_poem_templates where is_active and category = v_category
      order by template offset (v_template_seed % v_template_count) limit 1;
  else
    -- noodval als de tabel leeg/uitgeschakeld is
    v_category := 'wholesome';
    v_template := 'Write a wholesome poem about %s making everyone''s day a little better.';
  end if;

  v_prompt_text := format(v_template, v_subject_text);

  insert into public.daily_poetry_challenges (challenge_date, subject_type, nickname_id, user_id, subject_text, category, prompt_text)
  values (v_today, v_subject_type, v_nickname_id, v_user_id, v_subject_text, v_category, v_prompt_text)
  on conflict (challenge_date) do nothing
  returning * into v_row;

  if v_row.id is null then
    select * into v_row from public.daily_poetry_challenges where challenge_date = v_today;
  end if;

  return v_row;
end;
$$ language plpgsql security definer set search_path = public;
