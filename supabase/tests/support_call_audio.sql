-- ============================================================================
-- Regression test for migration 0105: who may ring, answer and signal a
-- support call.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/support_call_audio.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000005a1'),  -- user
  ('00000000-0000-0000-0000-0000000005a2'),  -- another user
  ('00000000-0000-0000-0000-0000000005b1'),  -- agent who answers
  ('00000000-0000-0000-0000-0000000005b2')   -- another agent
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000005%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level) values
  ('00000000-0000-0000-0000-0000000005b1', '*', 'edit'),
  ('00000000-0000-0000-0000-0000000005b2', '*', 'edit')
on conflict do nothing;

create temp table t_ids (call_id uuid);
grant select, insert, update on t_ids to authenticated;

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'FAILED: % was allowed', p_what;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated;

set local role authenticated;

-- 1. A user rings support as themselves -------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000005a1');
with r as (
  insert into public.support_calls (profile_id, caller_role, caller_name)
  values ('00000000-0000-0000-0000-0000000005a1', 'user', 'Aina')
  returning id
)
insert into t_ids select id from r;
do $$
begin
  if (select caller_id from public.support_calls where id = (select call_id from t_ids))
       is distinct from '00000000-0000-0000-0000-0000000005a1'::uuid then
    raise exception 'FAILED: caller_id not stamped';
  end if;
end $$;

-- ... but not as someone else, not as an agent, and not already answered.
select pg_temp.refused($$insert into public.support_calls (profile_id, caller_role)
  values ('00000000-0000-0000-0000-0000000005a2', 'user')$$, 'ringing as another user');
select pg_temp.refused($$insert into public.support_calls (profile_id, caller_role)
  values ('00000000-0000-0000-0000-0000000005a1', 'admin')$$, 'a user placing an agent call');
select pg_temp.refused($$insert into public.support_calls (profile_id, caller_role, answered_by)
  values ('00000000-0000-0000-0000-0000000005a1', 'user', '00000000-0000-0000-0000-0000000005b1')$$,
  'a user claiming an agent');

-- The caller cannot answer their own call or hand it to an agent.
select pg_temp.refused($$update public.support_calls set status = 'accepted'
  where id = (select call_id from t_ids)$$, 'the caller answering their own call');
select pg_temp.refused($$update public.support_calls set answered_by = '00000000-0000-0000-0000-0000000005b1'
  where id = (select call_id from t_ids)$$, 'the caller assigning an agent');

-- 2. Another user can neither see the call nor signal on it -----------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000005a2');
do $$
begin
  if exists (select 1 from public.support_calls where id = (select call_id from t_ids)) then
    raise exception 'FAILED: another user can see the call';
  end if;
end $$;
select pg_temp.refused($$insert into public.support_call_signals (call_id, kind)
  values ((select call_id from t_ids), 'offer')$$, 'a stranger signalling');

-- 3. An agent answers; the first answer wins --------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000005b1');
update public.support_calls
   set status = 'accepted', answered_by = '00000000-0000-0000-0000-0000000005b1', started_at = now()
 where id = (select call_id from t_ids) and status = 'ringing' and answered_by is null;
select pg_temp.as_user('00000000-0000-0000-0000-0000000005b2');
do $$
declare n int;
begin
  update public.support_calls
     set status = 'accepted', answered_by = '00000000-0000-0000-0000-0000000005b2'
   where id = (select call_id from t_ids) and status = 'ringing' and answered_by is null;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAILED: a second agent took an answered call'; end if;
end $$;

-- 4. The two people on the call signal; an agent not on it can't read them --
select pg_temp.as_user('00000000-0000-0000-0000-0000000005a1');
insert into public.support_call_signals (call_id, kind, payload)
values ((select call_id from t_ids), 'offer', '{"sdp":"v=0"}');
select pg_temp.refused($$insert into public.support_call_signals (call_id, sender, kind)
  values ((select call_id from t_ids), '00000000-0000-0000-0000-0000000005b1', 'answer')$$,
  'signalling as the other party');
select pg_temp.as_user('00000000-0000-0000-0000-0000000005b1');
insert into public.support_call_signals (call_id, kind, payload)
values ((select call_id from t_ids), 'answer', '{"sdp":"v=0"}');
do $$
begin
  if (select count(*) from public.support_call_signals where call_id = (select call_id from t_ids)) <> 2 then
    raise exception 'FAILED: the answering agent cannot read the signals';
  end if;
end $$;
select pg_temp.as_user('00000000-0000-0000-0000-0000000005b2');
do $$
begin
  if exists (select 1 from public.support_call_signals where call_id = (select call_id from t_ids)) then
    raise exception 'FAILED: an agent not on the call can read its signals';
  end if;
end $$;

-- 5. Hanging up clears the signals and the call stays ended ------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000005a1');
update public.support_calls set status = 'ended', ended_at = now() where id = (select call_id from t_ids);
select pg_temp.refused($$update public.support_calls set status = 'ringing'
  where id = (select call_id from t_ids)$$, 'reopening an ended call');
reset role;
do $$
begin
  if exists (select 1 from public.support_call_signals where call_id = (select call_id from t_ids)) then
    raise exception 'FAILED: signals outlived the call';
  end if;
end $$;

-- 6. An agent ringing a user is stamped as the caller -------------------------
set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000005b1');
insert into public.support_calls (profile_id, caller_role, caller_name)
values ('00000000-0000-0000-0000-0000000005a1', 'admin', 'Support');
reset role;
do $$
begin
  if not exists (select 1 from public.support_calls
                  where profile_id = '00000000-0000-0000-0000-0000000005a1'
                    and caller_role = 'admin'
                    and caller_id = '00000000-0000-0000-0000-0000000005b1') then
    raise exception 'FAILED: agent call not stamped with its caller';
  end if;
end $$;

-- 7. Signed-out clients can't probe who is on a call --------------------------
do $$
begin
  if has_function_privilege('anon', 'public.support_call_participant(uuid)', 'execute') then
    raise exception 'FAILED: anon can call support_call_participant';
  end if;
end $$;

select 'support_call_audio: all passed' as result;
rollback;
