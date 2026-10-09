-- ============================================================================
-- Regression test for migration 0130: the help assistant's search and the
-- rules on its two tables.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/help_articles.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000130a1'),  -- a rider
  ('00000000-0000-0000-0000-0000000130a2'),  -- somebody else
  ('00000000-0000-0000-0000-0000000130ad')   -- an admin
on conflict do nothing;
insert into public.profiles (id) select id from auth.users
 where id::text like '00000000-0000-0000-0000-0000000130%'
on conflict do nothing;
insert into public.admin_access (profile_id, page, access_level)
values ('00000000-0000-0000-0000-0000000130ad', '*', 'edit')
on conflict do nothing;

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

-- The title of the best article for a question, for an audience.
create or replace function pg_temp.top(p_query text, p_audience text default 'rider') returns text
language sql as $$ select title from public.help_search(p_query, p_audience, 1) $$;
grant execute on function pg_temp.top(text, text) to authenticated;

-- Whether an article is among the first three for a question.
create or replace function pg_temp.top3(p_query text, p_title text, p_audience text default 'rider') returns boolean
language sql as $$ select exists (select 1 from public.help_search(p_query, p_audience, 3) where title = p_title) $$;
grant execute on function pg_temp.top3(text, text, text) to authenticated;

set local role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-0000000130a1');

-- 1. Natural questions find their article -------------------------------------
do $$
declare
  r record;
begin
  for r in
    select * from (values
      ('how do I cancel my ride', 'How do I cancel a ride?'),
      ('I forgot my password', 'I forgot my PIN'),
      ('how to top up wallet', 'How do I top up my wallet?'),
      ('where is my receipt', 'Where are my past trips and receipts?'),
      ('change phone number', 'How do I change my phone number?'),
      ('dark mode', 'How do I switch to dark mode?'),
      ('send coins to friend', 'How do I send GET.coin to someone?'),
      ('add a stop', 'Can I add stops on the way?'),
      ('share my trip', 'How do I share my ride with family?'),
      ('is my ride recorded', 'What is VoiceProtection?'),
      -- Malay
      ('batal tempahan', 'How do I cancel a ride?'),
      ('lupa pin', 'I forgot my PIN')
    ) as t(q, expected)
  loop
    if pg_temp.top(r.q) is distinct from r.expected then
      raise exception 'FAILED: "%" found "%", expected "%"', r.q, pg_temp.top(r.q), r.expected;
    end if;
  end loop;
end $$;

-- 2. Typos still find it -----------------------------------------------------
do $$
begin
  if not pg_temp.top3('cancle my ride', 'How do I cancel a ride?') then
    raise exception 'FAILED: a misspelt "cancel" lost its article';
  end if;
  if not pg_temp.top3('recipt', 'Where are my past trips and receipts?') then
    raise exception 'FAILED: a misspelt "receipt" lost its article';
  end if;
  if exists (select 1 from public.help_search('pizza', 'rider')) then
    raise exception 'FAILED: something matched "pizza"';
  end if;
  if exists (select 1 from public.help_search('   ', 'rider')) then
    raise exception 'FAILED: an empty question matched';
  end if;
end $$;

-- 3. Audiences ------------------------------------------------------------------
do $$
begin
  if pg_temp.top('how do I go online', 'partner') is distinct from 'How do I go online and take requests?' then
    raise exception 'FAILED: a partner should find the go-online article';
  end if;
  if exists (select 1 from public.help_search('go online take requests', 'rider') where title = 'How do I go online and take requests?') then
    raise exception 'FAILED: a rider was shown a partner-only article';
  end if;
  if not pg_temp.top3('cancel my ride', 'How do I cancel a ride?', 'partner') then
    raise exception 'FAILED: a partner should see riders'' articles too';
  end if;
  if exists (select 1 from public.help_search('help articles unanswered questions', 'partner') where title = 'How do I add help articles?') then
    raise exception 'FAILED: a partner was shown an admin article';
  end if;
  if pg_temp.top('help articles unanswered questions', 'admin') is distinct from 'How do I add help articles?' then
    raise exception 'FAILED: an admin should find the admin article';
  end if;
end $$;

-- 4. Writes are the admin's; inactive articles are hidden ---------------------
select pg_temp.refused(
  $q$insert into public.help_articles (title, answer) values ('Mine', 'My answer')$q$, 'a rider adding an article');
update public.help_articles set title = 'Hijacked' where title = 'I forgot my PIN';
delete from public.help_articles where title = 'I forgot my PIN';
do $$
begin
  if not exists (select 1 from public.help_articles where title = 'I forgot my PIN') then
    raise exception 'FAILED: a rider changed or deleted an article';
  end if;
end $$;

select pg_temp.as_user('00000000-0000-0000-0000-0000000130ad');
insert into public.help_articles (id, title, answer, keywords)
values ('00000000-0000-0000-0000-0000000130f1', 'How do I find the zebra lounge?', 'Ask at the zebra desk.', array['zebra']);
update public.help_articles set active = false where title = 'I forgot my PIN';
do $$
begin
  if pg_temp.top('zebra lounge') is distinct from 'How do I find the zebra lounge?' then
    raise exception 'FAILED: a new article is not searchable';
  end if;
  if (select count(*) from public.help_articles where not active) <> 1 then
    raise exception 'FAILED: an admin should still see the inactive article';
  end if;
end $$;

select pg_temp.as_user('00000000-0000-0000-0000-0000000130a1');
do $$
begin
  if exists (select 1 from public.help_articles where title = 'I forgot my PIN') then
    raise exception 'FAILED: a rider can read an inactive article';
  end if;
  if exists (select 1 from public.help_search('forgot my pin', 'rider') where title = 'I forgot my PIN') then
    raise exception 'FAILED: an inactive article was searched';
  end if;
end $$;

-- 5. Questions: one's own, feedback only on one's own -------------------------
insert into public.help_questions (question, matched_article_id)
values ('How do I cancel?', (select id from public.help_articles where title = 'How do I cancel a ride?'));
insert into public.help_questions (question) values ('Can I ride a zebra?');
select pg_temp.refused(
  $q$insert into public.help_questions (user_id, question) values ('00000000-0000-0000-0000-0000000130a2', 'Spoofed')$q$,
  'logging a question as somebody else');
select pg_temp.refused($q$insert into public.help_questions (question) values ('')$q$, 'an empty question');
select pg_temp.refused(
  $q$insert into public.help_questions (question) values (repeat('x', 501))$q$, 'a question over 500 characters');
update public.help_questions set helpful = true where question = 'How do I cancel?';
select pg_temp.refused($q$update public.help_questions set question = 'Rewritten'$q$, 'rewriting a question');
do $$
begin
  if (select helpful from public.help_questions where question = 'How do I cancel?') is not true then
    raise exception 'FAILED: the asker could not mark their answer helpful';
  end if;
end $$;

select pg_temp.as_user('00000000-0000-0000-0000-0000000130a2');
update public.help_questions set helpful = false;
do $$
begin
  if exists (select 1 from public.help_questions) then
    raise exception 'FAILED: another account can read somebody''s questions';
  end if;
end $$;

select pg_temp.as_user('00000000-0000-0000-0000-0000000130ad');
do $$
begin
  if (select count(*) from public.help_questions) <> 2 then
    raise exception 'FAILED: an admin should read every question';
  end if;
  if (select helpful from public.help_questions where question = 'How do I cancel?') is not true then
    raise exception 'FAILED: another account changed somebody''s feedback';
  end if;
end $$;

reset role;
do $$
begin
  if has_table_privilege('anon', 'public.help_questions', 'insert') then
    raise exception 'FAILED: anon can log questions';
  end if;
  if not has_function_privilege('anon', 'public.help_search(text, text, int)', 'execute') then
    raise exception 'FAILED: a signed-out visitor cannot search';
  end if;
end $$;

select 'help_articles: all passed';

rollback;
