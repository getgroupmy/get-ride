-- ============================================================================
-- GET.ride test copy: scramble personal data (deploy/nas-testdb).
--
-- Runs on the NAS's COPY of the database after each nightly restore, when
-- Admin › Settings › Office NAS › Test database › "Personal data scrambled"
-- is on. Never on the live database: it refuses to run unless the session
-- says it is a test copy (the runner sets it; so do the tests):
--
--   PGOPTIONS='-c getride.test_copy=yes' psql "$COPY_URL" -v ON_ERROR_STOP=1 -f scramble.sql
--
-- What it does (README.md, "What is scrambled", lists the same):
--
--   names           a person's name: profiles / partners / emergency
--                   contacts / fleet owners / stand people "name", and every
--                   rider_name, partner_name, driver_name, recipient_name,
--                   owner_name, holder_name, caller_name, sender_name …,
--                   first/last/full/display_name     -> "Test 3fa9c1"
--   phones          phone, *_phone, mobile, msisdn   -> +601 and 10 digits
--   ID numbers      ic, owner_ic, read_ic, nric, passport, *_number / *_no
--                   of an ID, bank account_no        -> TEST + 12 letters
--   emails          email, *_email, emails           -> user-…@example.invalid
--   addresses       address, *_address, full_address -> "Test address …"
--   places          pickup_name / drop_name …        -> "Place …"
--   photo paths     photo, avatar, selfie, picture (and *_url, *_path),
--                   profile_image, id_image, image_front, file_url(_back),
--                   cargo / pickup proof paths       -> scrambled/….jpg
--   plates          plate, *_plate                   -> TST1234
--   IP addresses    ip, ip_address                   -> 192.0.2.x (TEST-NET)
--   birth dates     birth_date, date_of_birth, dob   -> 1 January, same year
--   chat text       body / message / content / text in *message* / *chat*
--                   tables                           -> [scrambled]
--   read results    raw_user_meta_data, identity_data, ai_verification,
--                   doc_read_jobs.result             -> {}
--   sign-in         auth sessions, refresh tokens, one-time tokens, MFA
--                   challenges, flow state and the auth audit log are
--                   emptied; every *_token in auth is blanked
--   secrets         in every JSON value, any field named like key, secret,
--                   token, password or apikey is blanked (API keys,
--                   payment gateway secrets in app_settings and the like;
--                   every key value in Admin › API Keys),
--                   and so is every text column named *secret* / *_key
--                   that is not a hash or an id
--
-- The same value becomes the same scrambled value everywhere in one run (a
-- phone in profiles and in partners still match), with a fresh random salt
-- each night, so the scrambled values can't be traced back. Kept as they
-- are: ids, times, amounts, statuses, settings, and map coordinates (needed
-- for routes and fares; they are points, not addresses).
--
-- Triggers are off while it runs (session_replication_role = replica), so
-- the guards on approved partners' name, phone, IC and photo (0185, 0277)
-- and the audit triggers don't stand in the way. Generated columns are
-- skipped (they follow their source). A column longer than its limit is cut.
--
-- To scramble one more column: add its name to the right pattern in
-- pg_temp.scramble_kind below, and to README.md.
-- ============================================================================

do $$
begin
  if coalesce(current_setting('getride.test_copy', true), '') <> 'yes' then
    raise exception 'scramble.sql only runs on the test copy (set getride.test_copy=yes).';
  end if;
end $$;

set session_replication_role = replica;

-- Which kind of personal data a column holds, or null.
create or replace function pg_temp.scramble_kind(p_schema text, p_table text, p_column text, p_type text)
returns text
language plpgsql
immutable
as $$
declare
  c text := lower(p_column);
  t text := lower(p_table);
  -- Tables whose plain "name" is a person's.
  v_people constant text[] := array['profiles', 'partners', 'emergency_contacts', 'dispatch_fleet_owners',
    'dispatch_stand_people', 'family_members', 'contacts', 'users', 'riders', 'drivers'];
  -- Settings and catalogue tables: images and names there are the app's own.
  v_skip constant text[] := array['app_branding', 'push_messages', 'push_schedules', 'media_assets',
    'vehicle_make_models', 'place_types', 'settings_renames', 'messaging_routes', 'country_phone_rules',
    'testdb_runs', 'testdb_runners', 'nas_services', 'admin_table_pages', 'schema_migrations'];
begin
  if t = any(v_skip) then
    return null;
  end if;
  if p_type = 'date' then
    return case when c in ('birth_date', 'date_of_birth', 'dob', 'birthday') then 'birth' end;
  end if;
  if p_type in ('jsonb', 'json') then
    return case
      when c in ('raw_user_meta_data', 'identity_data', 'ai_verification') then 'json'
      when t = 'doc_read_jobs' and c = 'result' then 'json'
      else 'secrets' end;
  end if;
  if p_type = 'inet' then
    return case when c ~ '(^|_)ip(_address)?$' then 'ip' end;
  end if;
  if p_schema = 'auth' then
    if c ~ '_token(_new|_current)?$' or c in ('encrypted_password', 'recovery_token', 'reauthentication_token') then
      return 'token';
    end if;
    if c in ('email_change', 'new_email') then return 'email'; end if;
    if c in ('phone_change', 'new_phone') then return 'phone'; end if;
  end if;
  if c ~ '(^|_)(photo|avatar|selfie|picture)(_url|_path|_uri)?$'
     or c in ('profile_image', 'id_image', 'image_front', 'image_back', 'file_url', 'file_url_back', 'selfie_url',
              'cargo_photo_path', 'pickup_proof_path') then
    return 'photo';
  end if;
  if c ~ '^(.*_)?emails?$' or c ~ 'email_address$' then return 'email'; end if;
  if c ~ '^(.*_)?(phone|mobile|msisdn)$' then return 'phone'; end if;
  if c ~ '^(.*_)?(ic|nric|mykad|passport|ic_number|ic_no|id_number|id_no|identity_number|identity_no|passport_no|passport_number|national_id|account_no|account_number)$' then
    return 'idnum';
  end if;
  if c ~ '^(.*_)?(first|last|middle|full|display|legal|nick)_?name$'
     or c ~ '^(rider|partner|driver|recipient|booked_for|owner|holder|caller|callee|reporter|sender|actor|from|to|read|contact|emergency_contact|customer|passenger|guardian|kin)_name$'
     or (c = 'name' and t = any(v_people)) then
    return 'name';
  end if;
  if c ~ '^(pickup|drop|dropoff|destination)_(name|place)$' then return 'place'; end if;
  if c ~ '(^|_)ip(_address)?$' then return 'ip'; end if;
  if c ~ '^(.*_)?address$' then return 'address'; end if;
  if c ~ '^(.*_)?plate$' then return 'plate'; end if;
  if c in ('body', 'message', 'content', 'text') and t ~ '(message|chat)' then return 'text'; end if;
  if (c ~ 'secret' or c ~ '(^|_)(api_?key|private_key|access_key|secret_key|password)$')
     and c !~ '(hash|_id|_at)$' then
    return 'secret';
  end if;
  return null;
end;
$$;

-- Every string in a JSON value under a key like key / secret / token /
-- password, blanked (and under "value" too when p_values: the stored API
-- keys). Other values as they are.
create or replace function pg_temp.scrub_json(j jsonb, p_values boolean default false)
returns jsonb
language sql
immutable
as $$
  select case jsonb_typeof(j)
    when 'object' then coalesce((
      select jsonb_object_agg(k, case
               when jsonb_typeof(v) = 'string'
                    and ((p_values and k = 'value')
                         or ((k ~* '(key|keys|secret|token|password|passwd|credentials?)$'
                              or k ~* '(^|_|-)(pass|private)$')
                             and k !~* '(hash|public|publishable|anon|site_?key|key_?id|label)'
                             and k !~* '(^id|_id|name)$'))
                 then to_jsonb(''::text)
               else pg_temp.scrub_json(v, p_values) end)
        from jsonb_each(j) e(k, v)), '{}'::jsonb)
    when 'array' then coalesce((select jsonb_agg(pg_temp.scrub_json(v, p_values) order by i)
                                  from jsonb_array_elements(j) with ordinality a(v, i)), '[]'::jsonb)
    else j end;
$$;

-- The scrambled form of one value (as SQL, over column expression x).
create or replace function pg_temp.scramble_expr(p_kind text, x text, p_salt text)
returns text
language sql
immutable
as $$
  select case p_kind
    when 'name'    then format($f$'Test ' || left(md5(%L || lower(btrim(%s))), 6)$f$, p_salt, x)
    when 'phone'   then format($f$'+601' || lpad(((('x' || left(md5(%L || regexp_replace(%s, '\D', '', 'g')), 15))::bit(60)::bigint %% 10000000000))::text, 10, '0')$f$, p_salt, x)
    when 'idnum'   then format($f$'TEST' || upper(left(md5(%L || upper(regexp_replace(%s, '[^A-Za-z0-9]', '', 'g'))), 12))$f$, p_salt, x)
    when 'email'   then format($f$'user-' || left(md5(%L || lower(btrim(%s))), 12) || '@example.invalid'$f$, p_salt, x)
    when 'address' then format($f$'Test address ' || left(md5(%L || %s), 8)$f$, p_salt, x)
    when 'place'   then format($f$'Place ' || left(md5(%L || %s), 6)$f$, p_salt, x)
    when 'photo'   then format($f$'scrambled/' || left(md5(%L || %s), 16) || '.jpg'$f$, p_salt, x)
    when 'plate'   then format($f$'TST' || lpad(((('x' || left(md5(%L || upper(regexp_replace(%s, '\s', '', 'g'))), 8))::bit(32)::bigint %% 10000))::text, 4, '0')$f$, p_salt, x)
    when 'ip'      then format($f$'192.0.2.' || (1 + (('x' || left(md5(%L || %s::text), 8))::bit(32)::bigint %% 254))::text$f$, p_salt, x)
    when 'text'    then $f$'[scrambled]'$f$
    when 'token'   then $f$''$f$
    when 'secret'  then $f$''$f$
  end;
$$;

do $$
declare
  v_salt text := gen_random_uuid()::text;
  v_schemas text[] := string_to_array(
    coalesce(nullif(current_setting('getride.scramble_schemas', true), ''), 'public,auth'), ',');
  r record;
  col record;
  v_sets text[];
  v_where text[];
  v_expr text;
  v_target text;
  v_rows bigint;
  v_total bigint := 0;
  v_cols int := 0;
begin
  for r in
    select n.nspname as s, c.relname as t
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where c.relkind in ('r', 'p') and n.nspname = any(v_schemas)
     order by 1, 2
  loop
    v_sets := '{}';
    v_where := '{}';
    for col in
      select a.attname as name, format_type(a.atttypid, a.atttypmod) as full_type,
             t.typname as udt, et.typname as elem, a.attnotnull as notnull,
             case when a.atttypmod > 4 and t.typname in ('varchar', 'bpchar') then a.atttypmod - 4 end as maxlen
        from pg_attribute a
        join pg_type t on t.oid = a.atttypid
        left join pg_type et on et.oid = t.typelem and t.typcategory = 'A'
       where a.attrelid = format('%I.%I', r.s, r.t)::regclass and a.attnum > 0 and not a.attisdropped
         and a.attgenerated = '' and a.attidentity = ''
    loop
      declare
        v_base text := coalesce(col.elem, col.udt);
        v_type text := case
          when v_base in ('text', 'varchar', 'bpchar', 'citext') then 'text'
          when v_base = 'date' then 'date'
          when v_base in ('jsonb', 'json') then v_base
          when v_base = 'inet' then 'inet'
          else null end;
        v_kind text;
        v_one text;
      begin
        if v_type is null then
          continue;
        end if;
        v_kind := pg_temp.scramble_kind(r.s, r.t, col.name, v_type);
        if v_kind is null then
          continue;
        end if;
        if col.elem is not null then
          -- Arrays: each element scrambled (text kinds only).
          if v_type <> 'text' or v_kind in ('secrets', 'json') then
            continue;
          end if;
          v_one := pg_temp.scramble_expr(v_kind, 'e', v_salt);
          v_expr := format('array(select %s from unnest(%I) e)', v_one, col.name);
          v_target := format('%I is not null and cardinality(%I) > 0', col.name, col.name);
        elsif v_kind = 'birth' then
          v_expr := format('date_trunc(''year'', %I)::date', col.name);
          v_target := format('%I is not null', col.name);
        elsif v_kind = 'json' then
          v_expr := format('''{}''::%s', v_type);
          v_target := format('%I is not null', col.name);
        elsif v_kind = 'secrets' then
          v_expr := format('pg_temp.scrub_json(%I::jsonb)::%s', col.name, v_type);
          v_target := format('%I is not null and %I::jsonb is distinct from pg_temp.scrub_json(%I::jsonb)',
                             col.name, col.name, col.name);
        elsif v_type = 'inet' then
          v_expr := format('(%s)::inet', pg_temp.scramble_expr('ip', quote_ident(col.name), v_salt));
          v_target := format('%I is not null', col.name);
        else
          v_expr := pg_temp.scramble_expr(v_kind, quote_ident(col.name), v_salt);
          if col.maxlen is not null then
            v_expr := format('left(%s, %s)', v_expr, col.maxlen);
          end if;
          v_target := format('%I is not null and %I <> %L', col.name, col.name, '');
        end if;
        v_sets := v_sets || format('%I = case when %s then %s else %I end', col.name, v_target, v_expr, col.name);
        v_where := v_where || format('(%s)', v_target);
        v_cols := v_cols + 1;
      end;
    end loop;
    if cardinality(v_sets) > 0 then
      execute format('update %I.%I set %s where %s', r.s, r.t, array_to_string(v_sets, ', '),
                     array_to_string(v_where, ' or '));
      get diagnostics v_rows = row_count;
      v_total := v_total + v_rows;
    end if;
  end loop;

  -- The keys in Admin › API Keys are stored as {"value": "…"}.
  for r in
    select n.nspname as s from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where c.relname = 'app_settings' and c.relkind = 'r' and n.nspname = any(v_schemas)
  loop
    execute format('update %I.app_settings set value = pg_temp.scrub_json(value, true) where key = %L',
                   r.s, 'api_providers');
  end loop;

  -- Sign-in state: nobody's session or token comes along.
  if 'auth' = any(v_schemas) then
    for r in
      select c.relname as t from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'auth' and c.relkind = 'r'
         and c.relname in ('sessions', 'refresh_tokens', 'one_time_tokens', 'mfa_challenges', 'mfa_amr_claims',
                           'flow_state', 'audit_log_entries', 'saml_relay_states')
    loop
      execute format('truncate auth.%I cascade', r.t);
    end loop;
  end if;

  raise notice 'scrambled % columns, % rows', v_cols, v_total;
end $$;

set session_replication_role = origin;
