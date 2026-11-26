-- =================================================================
-- 0099 — Kerstgedichten, winterbiertjes en kerstoutfits
--
-- Kerstgedichten (Poetry Wall, 26 november 2026 t/m 15 januari 2027):
--   elke dag een kerstopdracht met een bijnaam, voor iedereen dezelfde.
--   In ongeveer 2 op de 3 dagen gaat het over iemand van het gezelschap
--   zelf. De opdracht wordt de eerste keer dat iemand kijkt vastgelegd.
--   Iedereen kan 1 kerstgedicht per dag publiceren (een gewoon gedicht,
--   dus met de gewone Poetry XP).
--
-- Winterbiertjes: ieder lid kan een bier aanduiden als winterbier.
--
-- Kerstoutfits:
--   xm1..xm4 : voor iedereen, gratis, zolang de kerstperiode loopt
--   kq1      : 1 kerstgedicht geschreven EN 1 winterbiertje gedronken
--   kq2      : zelf 100 kerstballen verzameld
--
-- Vereist 0083, 0097 en 0098. Additief + idempotent: mag opnieuw.
-- =================================================================

create table if not exists public.winter_beers (
  beer_id uuid primary key references public.beers(id) on delete cascade,
  marked_by uuid references public.profiles(id),
  marked_at timestamptz not null default now()
);
create table if not exists public.xmas_poem_days (
  day date primary key,
  template int not null,
  prompt text not null,
  nickname_id uuid references public.nicknames(id) on delete set null,
  nickname_text text not null,
  person_name text,
  created_at timestamptz not null default now()
);
create table if not exists public.xmas_poems (
  poem_id uuid primary key references public.poems(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  day date not null references public.xmas_poem_days(day),
  unique (user_id, day)
);
alter table public.winter_beers enable row level security;
alter table public.xmas_poem_days enable row level security;
alter table public.xmas_poems enable row level security;
drop policy if exists "Winter beers: read" on public.winter_beers;
create policy "Winter beers: read" on public.winter_beers for select to authenticated using (public.is_app_member('officelore'));
drop policy if exists "Xmas poem days: read" on public.xmas_poem_days;
create policy "Xmas poem days: read" on public.xmas_poem_days for select to authenticated using (public.is_app_member('officelore'));
drop policy if exists "Xmas poems: read" on public.xmas_poems;
create policy "Xmas poems: read" on public.xmas_poems for select to authenticated using (public.is_app_member('officelore'));
-- geen schrijf-policies: alleen de functies hieronder schrijven

create or replace function public.set_winter_beer(p_beer uuid, p_on boolean)
returns jsonb as $$
begin
  if auth.uid() is null or not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  if not exists (select 1 from public.beers where id = p_beer) then raise exception 'Unknown beer'; end if;
  if p_on then
    insert into public.winter_beers (beer_id, marked_by) values (p_beer, auth.uid()) on conflict (beer_id) do nothing;
  else
    delete from public.winter_beers where beer_id = p_beer;
  end if;
  return jsonb_build_object('ok', true, 'winter', coalesce(p_on, false));
end;
$$ language plpgsql security definer set search_path = public;
revoke all on function public.set_winter_beer(uuid, boolean) from public, anon;
grant execute on function public.set_winter_beer(uuid, boolean) to authenticated;

-- de opdracht van een dag: bestaat ze nog niet, dan wordt ze nu gekozen
create or replace function public._xmas_poem_day(p_day date)
returns public.xmas_poem_days as $$
declare
  r public.xmas_poem_days;
  v_templates text[] := array[
    '{nick} staat onder de maretak. Wat gebeurt er?',
    '{nick} probeert de kerstboom recht te zetten.',
    'De kerstman leest de verlanglijst van {nick} en maakt zich zorgen.',
    '{nick} drinkt het allerlaatste warme wijntje op.',
    'Kerstavond: {nick} zit vast in de schoorsteen.',
    '{nick} staat achter het jeneverkraampje.',
    'Het cadeau van {nick} voor de Secret Santa.',
    '{nick} bakt kerstkoekjes. De brandweer is onderweg.',
    'Een ode aan de foute kersttrui van {nick}.',
    '{nick} zingt luidkeels kerstliedjes op kantoor.',
    'Rudolf is ziek. {nick} valt in als rendier.',
    '{nick} bouwt een sneeuwman die verdacht veel op een collega lijkt.',
    'Het kerstdiner volgens {nick}.',
    '{nick} blijft op om de kerstman te betrappen.',
    '{nick} en de verdwenen kalkoen.',
    'De eerste sneeuw valt en {nick} gaat naar buiten.',
    '{nick} pakt cadeautjes in met veel te veel plakband.',
    'De kerstlichtjes van {nick} zijn zichtbaar vanuit de ruimte.',
    '{nick} krijgt een hoofdrol in het kerstspel.',
    'Eén winterbiertje te veel: de nacht van {nick}.',
    '{nick} gaat voor het eerst in jaren schaatsen.',
    '{nick} proeft elk jeneverke op de kerstmarkt.',
    'Wat {nick} écht onder de kerstboom wil.',
    '{nick} begint als hulpelf van de kerstman.',
    'De goede voornemens van {nick}.',
    'Oudejaarsavond met {nick} en veel te veel vuurwerk.',
    '{nick} bewaakt het chocolademelkkraampje.',
    'Een liefdesbrief van {nick} aan de kerststronk.',
    '{nick} verdwaalt tussen de kerstbomen.',
    'Waarom {nick} toch op de lijst van de brave mensen hoort.',
    '{nick} en het mysterie van de lege adventskalender.',
    'Het kerstfeest op het werk: {nick} grijpt de micro.',
    '{nick} ruilt van plaats met de ezel in de kerststal.',
    'Het jaar van {nick}, verteld door een kerstbal.',
    '{nick} bestuurt de slee en kent de weg niet.',
    'Gourmetten met {nick}: een tragedie in vier pannetjes.',
    '{nick} wint de wedstrijd om de mooiste kerstboom, op verdachte wijze.',
    '{nick} in een sneeuwbalgevecht tegen heel de bureau.'
  ];
  v_idx int; v_txt text; v_main boolean; v_nid uuid; v_nick text; v_person text;
begin
  select * into r from public.xmas_poem_days where day = p_day;
  if found then return r; end if;
  perform pg_advisory_xact_lock(hashtext('xmas_poem_day:' || p_day::text));
  select * into r from public.xmas_poem_days where day = p_day;
  if found then return r; end if;

  select t.i::int, t.txt into v_idx, v_txt
    from unnest(v_templates) with ordinality as t(txt, i)
    order by exists (select 1 from public.xmas_poem_days d where d.template = t.i and d.day > p_day - 30), random()
    limit 1;

  v_main := random() < 0.67;
  with members as (
    select p.id,
           nullif(lower(regexp_replace(coalesce(p.display_name, ''), '[^A-Za-z]', '', 'g')), '') as n1,
           nullif(lower(regexp_replace(coalesce(p.first_name, ''), '[^A-Za-z]', '', 'g')), '') as n2
    from public.profiles p
    join public.app_memberships m on m.user_id = p.id and m.app_id = 'officelore' and m.is_active
  ), nick as (
    select n.id, n.nickname, n.person_real_name,
           (select mm.id from members mm
             where lower(regexp_replace(n.person_real_name, '[^A-Za-z]', '', 'g')) in (mm.n1, mm.n2) limit 1) as main_id
    from public.nicknames n
    where n.status <> 'Gearchiveerd'
  ), ranked as (
    -- eerst een persoon, dan een van diens bijnamen: wie veel bijnamen heeft komt niet vaker aan de beurt
    select nick.*,
           row_number() over (partition by coalesce(main_id::text, lower(person_real_name)) order by random()) as rn
    from nick
  )
  select id, nickname, person_real_name into v_nid, v_nick, v_person
    from ranked k
    order by (k.main_id is not null) <> v_main,
             exists (select 1 from public.xmas_poem_days d where d.nickname_id = k.id and d.day > p_day - 4),
             k.rn, random()
    limit 1;

  if v_nick is null then                                     -- nog geen enkele bijnaam
    select p.display_name, p.display_name into v_nick, v_person
      from public.profiles p
      join public.app_memberships m on m.user_id = p.id and m.app_id = 'officelore' and m.is_active
      order by random() limit 1;
  end if;

  insert into public.xmas_poem_days (day, template, prompt, nickname_id, nickname_text, person_name)
    values (p_day, v_idx, replace(v_txt, '{nick}', v_nick), v_nid, v_nick, v_person)
    returning * into r;
  return r;
end;
$$ language plpgsql security definer set search_path = public;
revoke all on function public._xmas_poem_day(date) from public, anon, authenticated;

create or replace function public.publish_xmas_poem(p_title text, p_content text, p_mood text default 'wholesome')
returns jsonb as $$
declare
  v_user uuid := auth.uid();
  v_day date := (now() at time zone 'Europe/Brussels')::date;
  d public.xmas_poem_days;
  v_poem uuid;
begin
  if v_user is null or not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  if v_day < date '2026-11-26' or v_day >= date '2027-01-16' then return jsonb_build_object('ok', false, 'reason', 'closed'); end if;
  if length(btrim(coalesce(p_title, ''))) = 0 or length(p_title) > 120 then raise exception 'Invalid title'; end if;
  if length(btrim(coalesce(p_content, ''))) = 0 or length(p_content) > 8000 then raise exception 'Invalid poem'; end if;
  d := public._xmas_poem_day(v_day);
  perform pg_advisory_xact_lock(hashtext('xmas_poem:' || v_user::text));
  if exists (select 1 from public.xmas_poems where user_id = v_user and day = v_day) then
    return jsonb_build_object('ok', false, 'reason', 'already');
  end if;
  insert into public.poems (author_user_id, title, content, mood, prompt_text_snapshot)
    values (v_user, btrim(p_title), p_content, p_mood, d.prompt)
    returning id into v_poem;
  insert into public.xmas_poems (poem_id, user_id, day) values (v_poem, v_user, v_day);
  return jsonb_build_object('ok', true, 'poem_id', v_poem);
end;
$$ language plpgsql security definer set search_path = public;
revoke all on function public.publish_xmas_poem(text, text, text) from public, anon;
grant execute on function public.publish_xmas_poem(text, text, text) to authenticated;

-- ---- kerstoutfits ----
insert into public.character_seasonal_outfits (id, name, season, genders, starts_on, ends_on, sort_order) values
  ('xm1', 'Kerstklassieker', 'christmas', '{f,m}', date '2026-11-26', date '2027-01-15', 40),
  ('xm2', 'Elf & rendier',   'christmas', '{f,m}', date '2026-11-26', date '2027-01-15', 50),
  ('xm3', 'Kerstglans',      'christmas', '{f,m}', date '2026-11-26', date '2027-01-15', 60),
  ('xm4', 'Kerstfiguur',     'christmas', '{f,m}', date '2026-11-26', date '2027-01-15', 70)
on conflict (id) do update set name = excluded.name, season = excluded.season, genders = excluded.genders, starts_on = excluded.starts_on,
  ends_on = excluded.ends_on, sort_order = excluded.sort_order;

-- 'sources' blijft leeg: deze twee vallen nooit uit een gewone quest
insert into public.character_outfit_sets (id, name, hint, unlock_kind, sources, pity_after, sort_order) values
  ('kq1', 'Winterfeest',      'Schrijf een kerstgedicht en drink een winterbiertje.', 'first_completion', '[]', null, 200),
  ('kq2', 'Koninklijke Kerst', 'Verzamel zelf 100 kerstballen.',                      'first_completion', '[]', null, 210)
on conflict (id) do update set name = excluded.name, hint = excluded.hint, unlock_kind = excluded.unlock_kind, sources = excluded.sources,
  pity_after = excluded.pity_after, sort_order = excluded.sort_order, is_active = true;

-- alles voor de app in een keer: de opdracht van vandaag, de kerstgedichten, jouw voortgang.
-- Verdiende quest-outfits worden hier meteen toegekend (een tweede keer doet niets).
create or replace function public.get_xmas_extras()
returns jsonb as $$
declare
  v_user uuid := auth.uid();
  v_day date := (now() at time zone 'Europe/Brussels')::date;
  v_open boolean;
  d public.xmas_poem_days;
  v_poem boolean; v_beer boolean; v_baubles int;
  v_new jsonb := '[]'::jsonb;
begin
  if v_user is null or not public.is_app_member('officelore') then raise exception 'Access denied'; end if;
  v_open := v_day >= date '2026-11-26' and v_day < date '2027-01-16';
  if v_open then d := public._xmas_poem_day(v_day); end if;

  v_poem := exists (select 1 from public.xmas_poems where user_id = v_user);
  v_beer := exists (
    select 1 from public.beer_consumption c
    join public.winter_beers w on w.beer_id = c.beer_id
    where c.user_id = v_user and c.quantity > 0
      and (c.created_at at time zone 'Europe/Brussels')::date between date '2026-11-26' and date '2027-01-15');
  v_baubles := coalesce((select sum(amount) from public.xmas_baubles where user_id = v_user), 0);

  if v_open and v_poem and v_beer then
    insert into public.user_character_outfits (user_id, set_id, source) values (v_user, 'kq1', 'xmas') on conflict do nothing;
    if found then v_new := v_new || '"kq1"'::jsonb; end if;
  end if;
  if v_open and v_baubles >= 100 then
    insert into public.user_character_outfits (user_id, set_id, source) values (v_user, 'kq2', 'xmas') on conflict do nothing;
    if found then v_new := v_new || '"kq2"'::jsonb; end if;
  end if;

  return jsonb_build_object(
    'open', v_open,
    'today', case when v_open then jsonb_build_object('day', d.day, 'prompt', d.prompt, 'nickname', d.nickname_text, 'person', d.person_name) end,
    'poems', coalesce((select jsonb_agg(jsonb_build_object('poem_id', x.poem_id, 'user_id', x.user_id, 'day', x.day, 'nickname', pd.nickname_text) order by x.day desc)
                       from public.xmas_poems x join public.xmas_poem_days pd on pd.day = x.day), '[]'::jsonb),
    'quest', jsonb_build_object('poem', v_poem, 'beer', v_beer, 'baubles', v_baubles, 'need', 100),
    'new_outfits', v_new
  );
end;
$$ language plpgsql security definer set search_path = public;
revoke all on function public.get_xmas_extras() from public, anon;
grant execute on function public.get_xmas_extras() to authenticated;
