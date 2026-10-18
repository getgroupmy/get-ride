-- ============================================================================
-- Regression test for migration 0217: the partner statement layout. Only an
-- admin with edit rights saves it; what is saved is cleaned (bounded text,
-- sizes, colours, a plain logo file name); any admin reads it.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/partner_statement_layout.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
end $$;

create or replace function pg_temp.as_user(p uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', coalesce(p::text, ''), true),
         set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
$$;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception 'FAILED: % was allowed', p_what;
exception when others then
  if sqlerrm like 'FAILED:%' then raise; end if;
end $$;

grant execute on function pg_temp.check(boolean, text), pg_temp.as_user(uuid), pg_temp.refused(text, text)
  to authenticated, anon;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000217e1'),  -- admin with edit rights
  ('00000000-0000-0000-0000-0000000217f1'),  -- admin who can only read
  ('00000000-0000-0000-0000-0000000217a1')   -- a driver
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000217e1', 'admin-settings-partner-statements', 'edit'),
  ('00000000-0000-0000-0000-0000000217f1', 'admin-settings-partner-statements', 'read');

set local role authenticated;

-- 1. Nothing saved: the built-in look.
select pg_temp.as_user('00000000-0000-0000-0000-0000000217f1');
select pg_temp.check(
  (select l->>'fontFamily' = 'helvetica' and l->'fields' = '{}'::jsonb and l->'logo'->>'path' = ''
     from public.partner_statement_layout() l),
  'no layout saved reads as the built-in one');

-- 2. Saving needs edit rights.
select pg_temp.refused($q$select public.set_partner_statement_layout('{}')$q$, 'a read-only admin saving');
select pg_temp.as_user('00000000-0000-0000-0000-0000000217a1');
select pg_temp.refused($q$select public.set_partner_statement_layout('{}')$q$, 'a driver saving');

-- 3. An editing admin saves; what is saved is cleaned.
select pg_temp.as_user('00000000-0000-0000-0000-0000000217e1');
select public.set_partner_statement_layout(jsonb_build_object(
  'fields', jsonb_build_object(
    'title', jsonb_build_object('en', '  Monthly Pay Slip  ', 'ms', repeat('x', 200)),
    'ic', jsonb_build_object('show', false),
    'bad id!', jsonb_build_object('show', false)),
  'sections', jsonb_build_array('activity', 'earnings', 'drop table'),
  'fontFamily', 'comic',
  'fonts', jsonb_build_object('title', 99, 'body', 10.5, 'nope', 9),
  'colors', jsonb_build_object('brand', '#12ab56', 'ink', 'red'),
  'logo', jsonb_build_object('path', '../../etc/passwd', 'position', 'right', 'width', 9999, 'dx', -500),
  'companySide', 'right'));

select pg_temp.check(
  (select l->'fields'->'title'->>'en' = 'Monthly Pay Slip' and length(l->'fields'->'title'->>'ms') = 80
      and l->'fields'->'ic'->'show' = 'false'::jsonb and not (l->'fields' ? 'bad id!')
     from public.partner_statement_layout() l),
  'labels trimmed and bounded, unknown ids dropped');
select pg_temp.check(
  (select l->'sections' = '["activity", "earnings"]'::jsonb from public.partner_statement_layout() l),
  'only plain section names kept');
select pg_temp.check(
  (select l->>'fontFamily' = 'helvetica' and (l->'fonts'->>'title')::numeric = 24
      and (l->'fonts'->>'body')::numeric = 10.5 and not (l->'fonts' ? 'nope')
     from public.partner_statement_layout() l),
  'font family and sizes bounded');
select pg_temp.check(
  (select l->'colors' = '{"brand": "#12AB56"}'::jsonb from public.partner_statement_layout() l),
  'only #RRGGBB colours kept');
select pg_temp.check(
  (select l->'logo' = '{"path": "", "position": "right", "width": 220, "dx": -200, "dy": 0}'::jsonb
     from public.partner_statement_layout() l),
  'a logo path with slashes refused, its size and shift bounded');
select public.set_partner_statement_layout('{"logo": {"path": "statement-logo-1760000000000.png"}}');
select pg_temp.check(
  (select l->'logo'->>'path' = 'statement-logo-1760000000000.png' from public.partner_statement_layout() l),
  'a plain file name kept');

-- 4. Too large is refused.
select pg_temp.refused(
  format($q$select public.set_partner_statement_layout(%L)$q$,
    jsonb_build_object('pad', repeat(md5('x'), 2000))),
  'a layout over 20 kB');

-- 5. Only admins upload to app-branding (the logo, splash and icon).
select pg_temp.as_user('00000000-0000-0000-0000-0000000217a1');
select pg_temp.refused(
  $q$insert into storage.objects (bucket_id, name) values ('app-branding', 'statement-logo-x.png')$q$,
  'a driver uploading a logo');
-- 0223: a read-only grant no longer writes; edit on the page that uses the bucket does.
select pg_temp.as_user('00000000-0000-0000-0000-0000000217f1');
select pg_temp.refused(
  $q$insert into storage.objects (bucket_id, name) values ('app-branding', 'statement-logo-r.png')$q$,
  'a read-only admin uploading a logo');
select pg_temp.as_user('00000000-0000-0000-0000-0000000217e1');
insert into storage.objects (bucket_id, name) values ('app-branding', 'statement-logo-y.png');
select pg_temp.check(
  exists (select 1 from storage.objects where bucket_id = 'app-branding' and name = 'statement-logo-y.png'),
  'an admin uploads a logo');
reset role;
set local role anon;
select pg_temp.refused(
  $q$insert into storage.objects (bucket_id, name) values ('app-branding', 'statement-logo-z.png')$q$,
  'anyone uploading signed out');
reset role;
set local role authenticated;

-- 6. Not readable without signing in.
reset role;
set local role anon;
select pg_temp.refused($q$select public.partner_statement_layout()$q$, 'reading it signed out');
reset role;

select 'partner_statement_layout: all passed';
rollback;
