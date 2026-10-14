-- ============================================================================
-- Regression test for migration 0177: rides completed before 0174 without a
-- commission are charged once, from their stored fare; charged ones are left.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/commission_backfill.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000177a1'),
  ('00000000-0000-0000-0000-0000000177b1')
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000177%'
on conflict do nothing;
insert into public.commission_rates (level, user_id, rate, active)
values ('user', '00000000-0000-0000-0000-0000000177b1', 0.10, true);

-- Inserted as completed (the owner, as the old rows were): no trigger
-- charged them. e1 has only `fare`, e2 an early-end `ride_fare`, e3 was
-- charged already.
insert into public.ride_requests (id, rider_id, partner_id, status, fare, ride_fare, commission_charged_at, commission_amount) values
  ('00000000-0000-0000-0000-0000000177e1', '00000000-0000-0000-0000-0000000177a1', '00000000-0000-0000-0000-0000000177b1', 'completed', 35, null, null, null),
  ('00000000-0000-0000-0000-0000000177e2', '00000000-0000-0000-0000-0000000177a1', '00000000-0000-0000-0000-0000000177b1', 'completed', 46, 40, null, null),
  ('00000000-0000-0000-0000-0000000177e3', '00000000-0000-0000-0000-0000000177a1', '00000000-0000-0000-0000-0000000177b1', 'completed', 50, 50, now(), 5);

\ir ../migrations/0177_commission_backfill.sql
-- Again: nothing more is charged.
\ir ../migrations/0177_commission_backfill.sql

do $$
begin
  if (select commission_amount from public.ride_requests where id = '00000000-0000-0000-0000-0000000177e1') is distinct from 3.50 then
    raise exception 'FAILED: a fare-only ride is charged on its fare';
  end if;
  if (select commission_amount from public.ride_requests where id = '00000000-0000-0000-0000-0000000177e2') is distinct from 4.00 then
    raise exception 'FAILED: an early-end ride is charged on its ride_fare';
  end if;
  if (select coalesce(sum(amount), 0) from public.wallet_transactions
       where user_id = '00000000-0000-0000-0000-0000000177b1' and kind = 'commission') <> -7.50 then
    raise exception 'FAILED: the driver is charged 7.50 in all, once';
  end if;
end $$;

select 'commission_backfill: all passed';
rollback;
