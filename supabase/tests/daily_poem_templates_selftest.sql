-- Daily poem templates: seed, selectie, RLS. Rapport = bewuste exception.
do $$
declare r text := ''; v_n int; v_c int; v_row public.daily_poetry_challenges; v_ok boolean;
begin
  select count(*), count(distinct category) into v_n, v_c from public.daily_poem_templates where is_active;
  r := r || format('%s templates in %s categorieen: %s', v_n, v_c, case when v_n >= 90 and v_c = 14 then 'PASS' else 'FAIL' end) || E'\n';

  select count(*) = 0 into v_ok from public.daily_poem_templates where template not like '%\%s%';
  r := r || 'alle templates bevatten %s: ' || case when v_ok then 'PASS' else 'FAIL' end || E'\n';

  delete from public.daily_poetry_challenges where challenge_date = current_date;
  v_row := public.get_or_create_daily_challenge();
  select exists(select 1 from public.daily_poem_templates t
                where t.category = v_row.category and format(t.template, v_row.subject_text) = v_row.prompt_text) into v_ok;
  r := r || format('daily (%s) komt uit tabel, subject ingevuld: %s', v_row.category, case when v_ok then 'PASS' else 'FAIL' end) || E'\n';

  -- idempotent: tweede call geeft dezelfde rij
  r := r || 'tweede call zelfde rij: ' || case when (public.get_or_create_daily_challenge()).id = v_row.id then 'PASS' else 'FAIL' end || E'\n';

  -- lege tabel -> noodval
  update public.daily_poem_templates set is_active = false;
  delete from public.daily_poetry_challenges where challenge_date = current_date;
  v_row := public.get_or_create_daily_challenge();
  r := r || 'noodval bij lege tabel: ' || case when v_row.category = 'wholesome' and v_row.prompt_text like 'Write a wholesome%' then 'PASS' else 'FAIL' end || E'\n';

  -- alle 14 categorieen zijn bereikbaar (offsets 0..13)
  select count(*) = 14 into v_ok from (select distinct category from public.daily_poem_templates) c;
  r := r || '14 categorieen: ' || case when v_ok then 'PASS' else 'FAIL' end || E'\n';
  raise exception E'\n%', r;
end $$;
