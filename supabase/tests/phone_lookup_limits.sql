-- ============================================================================
-- Regression test for migration 0173: the phone lookup is limited to 20 per
-- 10 minutes and 100 per day per address; another address is not held up.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/phone_lookup_limits.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

-- 20 in ten minutes, then refused.
select set_config('request.headers', '{"cf-connecting-ip":"198.51.100.173"}', true);
set local role anon;
do $$
begin
  for i in 1..20 loop
    perform * from public.profile_phone_lookup('+60100000173');
  end loop;
  begin
    perform * from public.profile_phone_lookup('+60100000173');
    raise exception 'FAILED: the 21st lookup in ten minutes should be refused';
  exception when others then
    if sqlerrm not like 'RATE_LIMITED:%' then raise; end if;
  end;
end $$;
reset role;

-- An address that used up its day is refused even though its
-- last ten minutes are empty.
select public.auth_rate_take('phone_lookup_day', '198.51.100.174', 100, interval '1 day')
  from generate_series(1, 100);
select set_config('request.headers', '{"cf-connecting-ip":"198.51.100.174"}', true);
set local role anon;
do $$
begin
  begin
    perform * from public.profile_phone_lookup('+60100000173');
    raise exception 'FAILED: an address past 100 lookups a day should be refused';
  exception when others then
    if sqlerrm not like 'RATE_LIMITED:%' then raise; end if;
  end;
end $$;
reset role;

-- A fresh address still answers.
select set_config('request.headers', '{"cf-connecting-ip":"198.51.100.175"}', true);
set local role anon;
do $$
begin
  if (select count(*) from public.profile_phone_lookup('+60100000173')) <> 1 then
    raise exception 'FAILED: a fresh address should get an answer';
  end if;
end $$;
reset role;

rollback;

select 'phone_lookup_limits: all passed';
