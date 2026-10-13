-- ============================================================================
-- Regression test for migration 0167: an account reads and changes only its
-- own notifications, and a retried event is kept once.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/user_notifications.sql
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000167a1'),
  ('00000000-0000-0000-0000-0000000167a2')
on conflict do nothing;
insert into public.profiles (id) values
  ('00000000-0000-0000-0000-0000000167a1'),
  ('00000000-0000-0000-0000-0000000167a2')
on conflict do nothing;

create or replace function pg_temp.check(p_ok boolean, p_msg text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_msg; end if;
end $$;

insert into public.user_notifications (id, profile_id, title, body, event_id) values
  ('00000000-0000-0000-0000-000000016701', '00000000-0000-0000-0000-0000000167a1', 'A1', 'one', 'e1'),
  ('00000000-0000-0000-0000-000000016702', '00000000-0000-0000-0000-0000000167a1', 'A2', 'two', null),
  ('00000000-0000-0000-0000-000000016703', '00000000-0000-0000-0000-0000000167a2', 'B1', 'other', null);

-- A retried outbox event is kept once; rows without an event never clash.
insert into public.user_notifications (profile_id, title, body, event_id)
values ('00000000-0000-0000-0000-0000000167a1', 'A1', 'one again', 'e1')
on conflict (profile_id, event_id) do nothing;
insert into public.user_notifications (profile_id, title, body)
values ('00000000-0000-0000-0000-0000000167a1', 'A3', 'three');
select pg_temp.check(
  (select count(*) from public.user_notifications where profile_id = '00000000-0000-0000-0000-0000000167a1') = 3,
  'a retried event was kept twice, or a row without one was refused');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000167a1","role":"authenticated"}', true);
set local role authenticated;

select pg_temp.check((select count(*) from public.user_notifications) = 3, 'reads another account''s notifications');
select pg_temp.check(
  public.notifications_mark_read(array['00000000-0000-0000-0000-000000016701'::uuid,
                                       '00000000-0000-0000-0000-000000016703'::uuid]) = 1,
  'marked another account''s notification read');
select pg_temp.check(public.notifications_mark_read() = 2, 'mark all read');
select pg_temp.check(
  public.notifications_delete(array['00000000-0000-0000-0000-000000016702'::uuid,
                                    '00000000-0000-0000-0000-000000016703'::uuid]) = 1,
  'deleted another account''s notification');

do $$
begin
  update public.user_notifications set read_at = null;
  raise exception 'FAILED: a client wrote to the table directly';
exception when insufficient_privilege then
  null;
end $$;

reset role;
select pg_temp.check(
  (select read_at from public.user_notifications where id = '00000000-0000-0000-0000-000000016703') is null
  and exists (select 1 from public.user_notifications where id = '00000000-0000-0000-0000-000000016703'),
  'the other account''s notification changed');

select pg_temp.check(
  not has_function_privilege('anon', 'public.notifications_mark_read(uuid[])', 'execute')
  and not has_function_privilege('anon', 'public.notifications_delete(uuid[])', 'execute'),
  'grants');

rollback;

select 'user_notifications: all passed';
