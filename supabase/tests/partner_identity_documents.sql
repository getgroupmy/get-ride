-- ============================================================================
-- Regression test for migration 0185: an approved partner's name, phone, IC
-- and photo are the admin's to change; documents are filed only on your own
-- partner record or vehicle; rewriting the AI verdict re-opens the review.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/partner_identity_documents.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000185a1'),  -- approved driver
  ('00000000-0000-0000-0000-0000000185a2')   -- applicant
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000185a%'
on conflict do nothing;

insert into public.partners (id, auth_user_id, name, phone, avatar_url, status) values
  ('00000000-0000-0000-0000-0000000185b1', '00000000-0000-0000-0000-0000000185a1', 'Dina', '+60110000185',
   'https://cdn.example/dina.jpg', 'approved'),
  ('00000000-0000-0000-0000-0000000185b2', '00000000-0000-0000-0000-0000000185a2', 'Uda', '+60110000186',
   null, 'unapproved');
insert into public.vehicle (id, plate, auth_user_id, owner_partner_id, status) values
  ('00000000-0000-0000-0000-0000000185c1', 'TST1851', '00000000-0000-0000-0000-0000000185a1',
   '00000000-0000-0000-0000-0000000185b1', 'approved');
insert into public.provider_documents (id, partner_id, auth_user_id, doc_id, doc_name, status, ai_verified) values
  ('00000000-0000-0000-0000-0000000185d1', '00000000-0000-0000-0000-0000000185b1',
   '00000000-0000-0000-0000-0000000185a1', 'licence', 'Driving licence', 'Approved', false);

create or replace function pg_temp.as_user(p uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p::text, true);
end $$;
grant execute on function pg_temp.as_user(uuid) to authenticated;

create or replace function pg_temp.refused(p_sql text, p_what text) returns void language plpgsql as $$
declare n integer;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when others then
    return;
  end;
  if n > 0 then
    raise exception 'FAILED: % was allowed', p_what;
  end if;
end $$;
grant execute on function pg_temp.refused(text, text) to authenticated;

set local role authenticated;

-- 1. The approved driver's identity is the admin's; an applicant's is their own --------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000185a1');
select pg_temp.refused(
  $q$update public.partners set avatar_url = 'https://evil.example/stock.jpg' where id = '00000000-0000-0000-0000-0000000185b1'$q$,
  'an approved driver swapping their photo');
select pg_temp.refused(
  $q$update public.partners set name = 'Someone Else' where id = '00000000-0000-0000-0000-0000000185b1'$q$,
  'an approved driver changing their name');
select pg_temp.as_user('00000000-0000-0000-0000-0000000185a2');
update public.partners set avatar_url = 'https://cdn.example/uda.jpg', name = 'Uda Bin Ali'
 where id = '00000000-0000-0000-0000-0000000185b2';

-- 2. Documents only on your own account ---------------------------------------------------
select pg_temp.refused(
  $q$insert into public.provider_documents (partner_id, auth_user_id, doc_id, doc_name)
     values ('00000000-0000-0000-0000-0000000185b1', '00000000-0000-0000-0000-0000000185a2', 'licence', 'Planted')$q$,
  'filing a document on another partner');
select pg_temp.refused(
  $q$insert into public.vehicle_documents (vehicle_id, auth_user_id, doc_id, doc_name)
     values ('00000000-0000-0000-0000-0000000185c1', '00000000-0000-0000-0000-0000000185a2', 'insurance', 'Planted')$q$,
  'filing a document on another partner''s vehicle');
insert into public.provider_documents (partner_id, auth_user_id, doc_id, doc_name)
values ('00000000-0000-0000-0000-0000000185b2', '00000000-0000-0000-0000-0000000185a2', 'licence', 'Driving licence');

-- 3. Rewriting the AI verdict re-opens the review ------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000185a1');
update public.provider_documents set ai_verified = true where id = '00000000-0000-0000-0000-0000000185d1';
insert into public.vehicle_documents (vehicle_id, auth_user_id, doc_id, doc_name)
values ('00000000-0000-0000-0000-0000000185c1', '00000000-0000-0000-0000-0000000185a1', 'insurance', 'Insurance');

reset role;
do $$
begin
  if (select status from public.provider_documents where id = '00000000-0000-0000-0000-0000000185d1') <> 'Pending Review' then
    raise exception 'FAILED: a rewritten AI verdict kept its approval';
  end if;
  if (select avatar_url from public.partners where id = '00000000-0000-0000-0000-0000000185b1') <> 'https://cdn.example/dina.jpg' then
    raise exception 'FAILED: the approved photo moved';
  end if;
  if (select count(*) from public.provider_documents where partner_id = '00000000-0000-0000-0000-0000000185b1') <> 1 then
    raise exception 'FAILED: a document was planted on the approved driver';
  end if;
end $$;

select 'partner_identity_documents: all passed';
rollback;
