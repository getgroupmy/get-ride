-- 0442 — partner registration identity gate (per country).
--
-- A new per-country switch, independent of the rider ID gate (0342) and the
-- live-selfie gate (0401), so a country may require identity verification of
-- riders, partners, both or neither. Stored in app_settings.partner_id_gate as
-- {country: {require: bool}}, the same shape as the live-selfie gate, with the
-- same admin-write guard. The app reads partner_id_gate_config() at the first
-- step of partner registration and runs the shared verify flow when it
-- requires; the admin review of every partner is the backstop.

create or replace function public.partner_id_gate_rule(p jsonb)
 returns jsonb
 language sql
 immutable
 set search_path to ''
as $function$
  select jsonb_build_object('require', coalesce((p->>'require')::boolean, false));
$function$;

create or replace function public.partner_id_gate_config()
 returns jsonb
 language sql
 stable security definer
 set search_path to ''
as $function$
  select coalesce(
    (select jsonb_object_agg(e.key, public.partner_id_gate_rule(e.value))
       from jsonb_each((select s.value from public.app_settings s where s.key = 'partner_id_gate')) e
      where jsonb_typeof(e.value) = 'object'),
    '{}'::jsonb);
$function$;

create or replace function public.set_partner_id_gate(p_country text, p_config jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_all jsonb; v_key text := nullif(btrim(p_country), '');
begin
  if auth.uid() is null or not public.caller_admin_can_write('rpc:set_partner_id_gate') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_key is null or jsonb_typeof(p_config) is distinct from 'object' then
    raise exception 'bad_request' using errcode = '22023';
  end if;
  v_all := coalesce((select s.value from public.app_settings s where s.key = 'partner_id_gate'), '{}'::jsonb)
           || jsonb_build_object(v_key, public.partner_id_gate_rule(p_config));
  insert into public.app_settings (key, value, updated_at) values ('partner_id_gate', v_all, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return public.partner_id_gate_config();
end;
$function$;

revoke all on function public.partner_id_gate_rule(jsonb) from public;
revoke all on function public.partner_id_gate_config() from public;
revoke all on function public.set_partner_id_gate(text, jsonb) from public;
grant execute on function public.partner_id_gate_rule(jsonb) to authenticated, service_role;
grant execute on function public.partner_id_gate_config() to authenticated, service_role;
grant execute on function public.set_partner_id_gate(text, jsonb) to authenticated, service_role;
