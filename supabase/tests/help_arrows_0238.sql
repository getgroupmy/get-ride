-- ============================================================================
-- Regression test for migration 0238: no "→" left in the help tables.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/help_arrows_0238.sql
--
-- Runs in one transaction and is rolled back. A failed assertion raises.
-- ============================================================================
begin;

create or replace function pg_temp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if p_ok is not true then
    raise exception 'FAILED: %', p_what;
  end if;
end $$;

-- Rows holding an arrow anywhere in the columns 0238 covers.
create or replace function pg_temp.arrows() returns bigint language sql as $$
  select (select count(*) from public.help_articles
           where strpos(title || ' ' || array_to_string(question_variants, ' ') || ' ' || answer || ' '
                        || array_to_string(keywords, ' ') || ' ' || category || ' '
                        || coalesce(action_label, '') || ' ' || coalesce(action_route, ''), '→') > 0)
       + (select count(*) from public.help_questions where strpos(question, '→') > 0)
$$;

-- 1. After the migrations, nothing has an arrow -------------------------------------------------
select pg_temp.check(pg_temp.arrows() = 0, 'no help article or question holds "→"');
select pg_temp.check(
  (select answer like 'Go to Settings > Change sign-in PIN. %'
     from public.help_articles where id = '68656c70-0000-4000-8000-000000000004'),
  'a menu path reads "Settings > Change sign-in PIN"');
-- The search document follows the new text (the update trigger rebuilt it).
select pg_temp.check(
  (select bool_and(search_doc =
      setweight(to_tsvector('english'::regconfig, title), 'A') ||
      setweight(to_tsvector('english'::regconfig, array_to_string(question_variants, ' ')), 'A') ||
      setweight(to_tsvector('english'::regconfig, array_to_string(keywords, ' ')), 'B') ||
      setweight(to_tsvector('english'::regconfig, answer), 'C'))
     from public.help_articles),
  'search_doc matches the text');

-- 2. An admin's article, with and without spaces, in every column -------------------------------
insert into auth.users (id) values ('00000000-0000-0000-0000-0000000238a1') on conflict do nothing;
insert into public.profiles (id) values ('00000000-0000-0000-0000-0000000238a1') on conflict do nothing;
insert into public.help_articles (id, title, question_variants, answer, keywords, category, action_label, action_route)
values ('00000000-0000-0000-0000-0000000238b1', 'Wallet → Receive',
        array['Where is Account→Safety?', 'plain']::text[],
        'Open Wallet → Receive.' || chr(10) || chr(10) || 'Then Account→Safety → SOS.',
        array['a→b', 'c']::text[], 'Wallet → QR', 'Wallet → Receive', '/wallet');
insert into public.help_questions (user_id, question)
values ('00000000-0000-0000-0000-0000000238a1', 'where is Settings → Bluetooth');
select pg_temp.check(pg_temp.arrows() = 2, 'the test rows hold arrows');

\ir ../migrations/0238_help_arrows.sql

select pg_temp.check(pg_temp.arrows() = 0, 'the migration clears every arrow');
select pg_temp.check(
  (select title = 'Wallet > Receive'
      and question_variants = array['Where is Account>Safety?', 'plain']::text[]
      and answer = 'Open Wallet > Receive.' || chr(10) || chr(10) || 'Then Account>Safety > SOS.'
      and keywords = array['a>b', 'c']::text[]
      and category = 'Wallet > QR'
      and action_label = 'Wallet > Receive'
     from public.help_articles where id = '00000000-0000-0000-0000-0000000238b1'),
  'spacing and array order are kept');
select pg_temp.check(
  (select question = 'where is Settings > Bluetooth' from public.help_questions
    where user_id = '00000000-0000-0000-0000-0000000238a1'),
  'a logged question is cleared too');
select pg_temp.check(
  (select search_doc @@ to_tsquery('english', 'receive') from public.help_articles
    where id = '00000000-0000-0000-0000-0000000238b1'),
  'the changed article is still found');

-- 3. Running it again changes nothing ----------------------------------------------------------
create temp table before_rerun as
  select id, ctid::text as at from public.help_articles
  union all select id, ctid::text from public.help_questions;

\ir ../migrations/0238_help_arrows.sql

select pg_temp.check(
  not exists (select 1 from before_rerun b
               where b.at is distinct from coalesce(
                 (select ctid::text from public.help_articles a where a.id = b.id),
                 (select ctid::text from public.help_questions q where q.id = b.id))),
  'a second run updates no row');

rollback;

select 'help_arrows_0238: all passed';
