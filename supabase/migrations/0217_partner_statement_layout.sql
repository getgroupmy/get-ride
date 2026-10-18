-- ============================================================================
-- 0217 — Partner statement layout
--
-- Admin → Partner statements → Layout: which fields a statement shows and
-- what they are called (English and Malay), the order of the partner lines
-- and of the blocks, the font and its sizes, the colours, and the logo (a
-- file in the public `app-branding` bucket) with where it sits.
--
-- Kept in app_settings 'partner_statement_layout'. The partner-statement
-- function reads it (supabase/functions/_shared/statement_layout.ts cleans
-- it again) and redraws a kept final statement when it changes, without
-- marking it Revised; partner_statements.layout_hash records which layout a
-- copy was drawn with.
--
-- Only admins with edit rights on Partner statements save it. Nothing here
-- changes a statement's numbers.
-- ============================================================================

insert into public.app_settings (key, value) values ('partner_statement_layout', '{}'::jsonb)
on conflict (key) do nothing;

alter table public.partner_statements add column if not exists layout_hash text;

-- What may be saved: known shapes only, text and numbers bounded. The
-- function's own cleaning decides the rest (unknown field ids, ranges).
create or replace function public.partner_statement_layout_clean(p jsonb)
returns jsonb
language sql
immutable
set search_path = public
as $$
  with src as (
    select case when jsonb_typeof(p) = 'object' then p else '{}'::jsonb end as v
  ),
  fields as (
    select coalesce(jsonb_object_agg(k, jsonb_strip_nulls(jsonb_build_object(
             'show', case when f->'show' = 'false'::jsonb then false end,
             'en', nullif(left(btrim(coalesce(f->>'en', '')), 80), ''),
             'ms', nullif(left(btrim(coalesce(f->>'ms', '')), 80), '')))), '{}'::jsonb) as v
      from src, jsonb_each(case when jsonb_typeof(src.v->'fields') = 'object' then src.v->'fields' else '{}' end) as e(k, f)
     where k ~ '^[A-Za-z]{1,40}$' and jsonb_typeof(f) = 'object'
  ),
  ids as (
    select key, coalesce((
      select jsonb_agg(x) from (
        select x from jsonb_array_elements_text(
          case when jsonb_typeof(src.v->key) = 'array' then src.v->key else '[]' end) x
         where x ~ '^[A-Za-z]{1,40}$' limit 20) t), '[]'::jsonb) as v
      from src, unnest(array['sections', 'partnerOrder']) key
  ),
  fonts as (
    select coalesce(jsonb_object_agg(k, least(24, greatest(6, (f #>> '{}')::numeric))), '{}'::jsonb) as v
      from src, jsonb_each(case when jsonb_typeof(src.v->'fonts') = 'object' then src.v->'fonts' else '{}' end) as e(k, f)
     where k in ('company', 'title', 'heading', 'body', 'total', 'table', 'small') and jsonb_typeof(f) = 'number'
  ),
  colors as (
    select coalesce(jsonb_object_agg(k, upper(f #>> '{}')), '{}'::jsonb) as v
      from src, jsonb_each(case when jsonb_typeof(src.v->'colors') = 'object' then src.v->'colors' else '{}' end) as e(k, f)
     where k in ('brand', 'ink', 'muted', 'rule', 'badge', 'watermark') and (f #>> '{}') ~ '^#[0-9A-Fa-f]{6}$'
  ),
  logo as (
    select case when jsonb_typeof(src.v->'logo') = 'object' then src.v->'logo' else '{}' end as l from src
  )
  select jsonb_build_object(
    'fields', (select v from fields),
    'sections', (select v from ids where key = 'sections'),
    'partnerOrder', (select v from ids where key = 'partnerOrder'),
    'fontFamily', case when src.v->>'fontFamily' in ('times', 'courier') then src.v->>'fontFamily' else 'helvetica' end,
    'fonts', (select v from fonts),
    'colors', (select v from colors),
    'logo', jsonb_build_object(
      'path', case when coalesce(logo.l->>'path', '') ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$' then logo.l->>'path' else '' end,
      'position', case when logo.l->>'position' in ('center', 'right') then logo.l->>'position' else 'left' end,
      'width', case when jsonb_typeof(logo.l->'width') = 'number' then least(220, greatest(20, round((logo.l->>'width')::numeric))) else 70 end,
      'dx', case when jsonb_typeof(logo.l->'dx') = 'number' then least(200, greatest(-200, round((logo.l->>'dx')::numeric))) else 0 end,
      'dy', case when jsonb_typeof(logo.l->'dy') = 'number' then least(200, greatest(-200, round((logo.l->>'dy')::numeric))) else 0 end),
    'companySide', case when src.v->>'companySide' = 'right' then 'right' else 'left' end)
  from src, logo;
$$;

-- Read by the admin page (any admin) and, as the service role, the PDF function.
create or replace function public.partner_statement_layout()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.partner_statement_layout_clean(
    coalesce((select value from public.app_settings where key = 'partner_statement_layout'), '{}'));
$$;
revoke execute on function public.partner_statement_layout() from public, anon;
grant execute on function public.partner_statement_layout() to authenticated;

create or replace function public.set_partner_statement_layout(p_layout jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.caller_can_edit_statements() then
    raise exception 'Only an admin with edit rights can change partner statements.' using errcode = '42501';
  end if;
  if pg_column_size(p_layout) > 20000 then
    raise exception 'That layout is too large.' using errcode = '22023';
  end if;
  v := public.partner_statement_layout_clean(p_layout);
  insert into public.app_settings (key, value, updated_at) values ('partner_statement_layout', v, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return v;
end;
$$;
revoke execute on function public.set_partner_statement_layout(jsonb) from public, anon;
grant execute on function public.set_partner_statement_layout(jsonb) to authenticated;

-- ---- app-branding: admins write, everyone reads ---------------------------------------------
-- The bucket was writable by anyone, signed in or not (baseline), so a
-- stranger could replace the splash, the app icon, or now the logo printed on
-- every statement. Only admins upload, replace or delete; reading stays public.
drop policy if exists "app-branding insert" on storage.objects;
drop policy if exists "app-branding update" on storage.objects;
drop policy if exists "app-branding delete" on storage.objects;

create policy "app-branding insert"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'app-branding' and (select public.caller_is_admin()));

create policy "app-branding update"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'app-branding' and (select public.caller_is_admin()))
  with check (bucket_id = 'app-branding' and (select public.caller_is_admin()));

create policy "app-branding delete"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'app-branding' and (select public.caller_is_admin()));
