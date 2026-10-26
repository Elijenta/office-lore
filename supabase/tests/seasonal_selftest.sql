-- SELF-TEST for 0083_seasonal_outfits.sql (safe: rolled back)
do $$
declare
  v_report text := ''; m uuid; v_err text; r jsonb;
begin
  select p.id into m from public.profiles p join public.app_memberships mm on mm.user_id = p.id and mm.app_id = 'officelore' and mm.is_active order by p.display_name limit 1;
  perform set_config('request.jwt.claim.sub', m::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true);
  delete from public.room_profiles where user_id = m;
  update public.character_seasonal_outfits set starts_on = (now() at time zone 'Europe/Brussels')::date - 2, ends_on = (now() at time zone 'Europe/Brussels')::date + 5;

  -- inside the window: anybody, for the right body
  r := public.set_room_character('female', 'fhw1');
  if r->'loadout'->>'outfit' <> 'fhw1' then raise exception 'FAIL 1: %', r; end if;
  r := public.set_room_character('female', 'fhw2');
  r := public.set_room_character('male', 'mhw1');
  r := public.set_room_character('male', 'mhw3');
  begin perform public.set_room_character('male', 'mhw2'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 2: the female-only vampire on a male body'; end if;
  begin perform public.set_room_character('female', 'fhw3'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 3: the male-only zombie on a female body'; end if;
  begin perform public.set_room_character('female', 'fhw9'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 4: an unknown seasonal outfit'; end if;
  v_report := v_report || 'PASS 🎃 inside the window anybody can pick the Pirate, the Vampire (female) and the Zombie (male); the wrong body or an unknown code is refused' || E'\n';

  -- after the window: not newly pickable, but whoever wears it keeps it
  r := public.set_room_character('male', 'mhw1');
  update public.character_seasonal_outfits set starts_on = (now() at time zone 'Europe/Brussels')::date - 40, ends_on = (now() at time zone 'Europe/Brussels')::date - 1;
  r := public.set_room_character('male', 'mhw1');                         -- already wearing it: allowed
  if r->'loadout'->>'outfit' <> 'mhw1' then raise exception 'FAIL 5: lost the outfit after the season'; end if;
  begin perform public.set_room_character('male', 'mhw3'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 6: picked an expired seasonal outfit'; end if;
  r := public.set_room_character('male', null);                            -- take it off
  begin perform public.set_room_character('male', 'mhw1'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 7: picked it again after the season'; end if;
  v_report := v_report || 'PASS ⏳ after the window: nobody can newly pick it, whoever wears it keeps it (even when saving their base again) until they take it off' || E'\n';

  -- the normal outfits still work, and locked special sets are still locked
  r := public.set_room_character('female', 'f1');
  begin perform public.set_room_character('female', 'flg1'); v_err := null; exception when others then v_err := sqlerrm; end;
  if v_err is null then raise exception 'FAIL 8: a locked special outfit was accepted'; end if;
  v_report := v_report || 'PASS 👗 standard outfits still free, special sets still locked' || E'\n';
  raise exception E'\n%', v_report;
end $$;
