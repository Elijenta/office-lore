-- DEV ONLY (a project that only you use): give every account that has signed up in the dev app access to Office Lore.
-- Run it after the 3 dev accounts have signed up with "Registreren" on localhost in DEV mode. Safe to run again.
insert into public.app_memberships (app_id, user_id)
  select 'officelore', p.id from public.profiles p
  on conflict do nothing;
select p.display_name, m.is_active from public.profiles p join public.app_memberships m on m.user_id = p.id and m.app_id = 'officelore' order by p.created_at;
