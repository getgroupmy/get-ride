-- ============================================================================
-- Regression test for migration 0339: per-service enabling.
--   * reg_type_blocked_keys: the ptr_key()s of the partner types with a failed
--     registration rule;
--   * reg_has_ready_type: at least one selected type is ready (mixed → yes,
--     all-blocked → no, none-blocked → yes);
--   * partner_type_ready: one named type's readiness;
--   * driver_partner_service_ok: a service dispatches only through a type that
--     both allows it and is ready — eHailing dispatches while Teksi waits, a
--     wholly-blocked partner takes nothing, and a type turns on by itself the
--     moment it stops being blocked (its documents approved).
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/per_service_enable_0339.sql
--
-- Self-contained: it stubs the dependencies 0339 builds on (reg_rule_checks &
-- co.) so the per-service DECISION logic is tested on its own, on any
-- Postgres, and runs in one transaction that is rolled back. The stub
-- reg_rule_checks marks a type failed iff it is listed in the partner row's
-- blocked_types, which is exactly the shape the real reg_rule_checks produces
-- (one row per type, labelled with its type, status 'failed'/'passed').
-- Made-up people only.
-- ============================================================================
begin;

-- ---- Stub dependencies -----------------------------------------------------
create table public.partners(
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid, partner_type text, partner_types text[], blocked_types text[]);

create or replace function public.ptr_key(p text) returns text language sql immutable as $$
  select lower(btrim(coalesce(p,''))) $$;
create or replace function public.ptr_text_array(p jsonb) returns text[] language sql immutable as $$
  select case when jsonb_typeof(p)='array' then array(select jsonb_array_elements_text(p)) else '{}'::text[] end $$;
create or replace function public.partner_type_rules(p_name text) returns jsonb language sql immutable as $$
  select jsonb_build_object('name', p_name) $$;
create or replace function public.partner_type_allows_service(p_type text, p_service text) returns boolean language sql immutable as $$
  select lower(coalesce(p_service,'')) like lower(coalesce(p_type,''))||'%' $$;
create or replace function public.reg_rule_failures(p_checks jsonb) returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(x.c order by x.n), '[]'::jsonb)
    from jsonb_array_elements(coalesce(p_checks,'[]'::jsonb)) with ordinality x(c,n)
   where x.c ->> 'status' = 'failed' $$;
create or replace function public.reg_rule_checks(p_row jsonb) returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('type', t, 'rule','driver_permit',
      'status', case when (p_row->'blocked_types') ? t then 'failed' else 'passed' end)), '[]'::jsonb)
    from jsonb_array_elements_text(coalesce(p_row->'partner_types','[]'::jsonb)) t $$;

-- ---- The functions under test, verbatim from migration 0339 ---------------
create or replace function public.reg_type_blocked_keys(p_row jsonb) returns text[] language sql stable as $$
  select coalesce(array_agg(distinct public.ptr_key(e.x ->> 'type'))
      filter (where nullif(btrim(coalesce(e.x ->> 'type','')),'') is not null), '{}')
    from jsonb_array_elements(public.reg_rule_failures(public.reg_rule_checks(p_row))) e(x) $$;

create or replace function public.reg_has_ready_type(p_row jsonb) returns boolean language sql stable as $$
  select case when coalesce(cardinality(bk.k),0)=0 then true
    else exists (select 1 from unnest(public.ptr_text_array(p_row->'partner_types')) as t
       where nullif(btrim(coalesce(t,'')),'') is not null
         and not (public.ptr_key(public.partner_type_rules(t)->>'name') = any (bk.k))) end
  from (select public.reg_type_blocked_keys(p_row) as k) bk $$;

create or replace function public.partner_type_ready(p_driver uuid, p_type text) returns boolean language plpgsql stable as $$
declare p public.partners%rowtype;
begin
  if p_driver is null or nullif(btrim(coalesce(p_type,'')),'') is null then return true; end if;
  select * into p from public.partners where auth_user_id = p_driver order by id limit 1;
  if not found then return true; end if;
  return public.ptr_key(public.partner_type_rules(p_type) ->> 'name') <> all(public.reg_type_blocked_keys(to_jsonb(p)));
end $$;

create or replace function public.driver_partner_service_ok(p_driver uuid, p_service text) returns boolean language plpgsql stable as $$
declare p public.partners%rowtype; v_types text[]; v_blocked text[];
begin
  if p_driver is null or coalesce(btrim(p_service),'')='' or lower(btrim(p_service)) ~ '^(extra|hail):' then return true; end if;
  select * into p from public.partners where auth_user_id = p_driver order by id limit 1;
  if not found then return true; end if;
  v_types := array(select btrim(t) from unnest(case when coalesce(cardinality(p.partner_types),0)>0 then p.partner_types else array[p.partner_type] end) as t where coalesce(btrim(t),'')<>'');
  if coalesce(cardinality(v_types),0)=0 then return true; end if;
  v_blocked := public.reg_type_blocked_keys(to_jsonb(p));
  return exists (select 1 from unnest(v_types) as t
     where public.partner_type_allows_service(t, p_service)
       and public.ptr_key(public.partner_type_rules(t) ->> 'name') <> all(v_blocked));
end $$;

-- ---- Seed: A mixed, B all blocked, C none blocked -------------------------
insert into public.partners(auth_user_id, partner_types, blocked_types) values
  ('00000000-0000-0000-0000-0000000000a1', array['eHailing','Teksi'], array['Teksi']),
  ('00000000-0000-0000-0000-0000000000a2', array['eHailing','Teksi'], array['eHailing','Teksi']),
  ('00000000-0000-0000-0000-0000000000a3', array['eHailing','Teksi'], array[]::text[]);

-- ---- Assert ----------------------------------------------------------------
do $$
declare a uuid := '00000000-0000-0000-0000-0000000000a1';
        b uuid := '00000000-0000-0000-0000-0000000000a2';
        c uuid := '00000000-0000-0000-0000-0000000000a3';
        pa jsonb; pb jsonb;
begin
  select to_jsonb(p) into pa from public.partners p where auth_user_id=a;
  select to_jsonb(p) into pb from public.partners p where auth_user_id=b;
  if public.reg_type_blocked_keys(pa) <> array['teksi'] then raise exception 'blocked_keys A wrong: %', public.reg_type_blocked_keys(pa); end if;
  if not public.reg_has_ready_type(pa) then raise exception 'A should have a ready type'; end if;
  if public.reg_has_ready_type(pb) then raise exception 'B (all blocked) should have no ready type'; end if;
  if not public.partner_type_ready(a,'eHailing') then raise exception 'A eHailing should be ready'; end if;
  if public.partner_type_ready(a,'Teksi') then raise exception 'A Teksi should be blocked'; end if;
  if not public.driver_partner_service_ok(a,'eHailingRide') then raise exception 'A should dispatch eHailing'; end if;
  if public.driver_partner_service_ok(a,'TeksiRide') then raise exception 'A should NOT dispatch Teksi'; end if;
  if public.driver_partner_service_ok(b,'eHailingRide') then raise exception 'B should dispatch nothing'; end if;
  if not public.driver_partner_service_ok(c,'eHailingRide') then raise exception 'C should dispatch eHailing'; end if;
  if not public.driver_partner_service_ok(c,'TeksiRide') then raise exception 'C should dispatch Teksi'; end if;
  -- Auto-enable: Teksi turns on by itself once it stops being blocked.
  update public.partners set blocked_types = array[]::text[] where auth_user_id=a;
  if not public.driver_partner_service_ok(a,'TeksiRide') then raise exception 'A Teksi should auto-enable once unblocked'; end if;
end $$;

rollback;
