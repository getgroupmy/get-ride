-- 0130: The in-app help assistant's knowledge base.
--
-- The assistant answers questions about the app without any AI provider: it
-- retrieves the best-matching article from `help_articles` and shows its
-- answer. `help_search` ranks articles by full-text match (title and
-- alternate phrasings weighted A, keywords B, answer C) plus trigram
-- similarity, so a typo or a two-word question still finds its article. The
-- app carries the same articles (assets/help/help_articles.json, generated
-- into lib/src/core/help_kb.dart by scripts/gen_help_kb.dart, which also
-- writes the seed at the end of this file) and ranks them on the device when
-- this function cannot be reached.
--
-- `help_questions` logs what people asked, which article answered it and
-- whether they found it helpful, so an admin can see the questions nothing
-- answered (Admin → Help articles → Unanswered questions) and write an
-- article for them.

-- Supabase keeps extensions in their own schema; a project that already has
-- pg_trgm elsewhere keeps it there (both are on help_search's search_path).
create schema if not exists extensions;
create extension if not exists pg_trgm with schema extensions;
-- help_search runs as its caller, who needs the trigram functions (Supabase
-- already grants this; a database built otherwise may not).
grant usage on schema extensions to anon, authenticated;

create table if not exists public.help_articles (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(btrim(title)) between 1 and 200),
  -- Other ways people ask the same question.
  question_variants text[] not null default '{}',
  -- Plain text with blank-line paragraphs.
  answer text not null check (length(btrim(answer)) between 1 and 4000),
  keywords text[] not null default '{}',
  audience text not null default 'all' check (audience in ('all', 'rider', 'partner', 'admin')),
  category text not null default '' check (length(category) <= 60),
  -- An in-app screen the answer can open (a go_router path such as
  -- '/account/settings/pin'), with the button's label.
  action_label text check (action_label is null or length(btrim(action_label)) between 1 and 60),
  action_route text check (action_route is null or action_route ~ '^/[A-Za-z0-9/_-]*$'),
  sort integer not null default 0,
  active boolean not null default true,
  search_doc tsvector,
  updated_at timestamptz not null default now()
);

-- Kept by a trigger rather than a generated column: array_to_string is only
-- STABLE, which a generated column refuses.
create or replace function public.help_articles_search_doc()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.search_doc :=
    setweight(to_tsvector('english'::regconfig, coalesce(new.title, '')), 'A') ||
    setweight(to_tsvector('english'::regconfig, array_to_string(coalesce(new.question_variants, '{}'), ' ')), 'A') ||
    setweight(to_tsvector('english'::regconfig, array_to_string(coalesce(new.keywords, '{}'), ' ')), 'B') ||
    setweight(to_tsvector('english'::regconfig, coalesce(new.answer, '')), 'C');
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists help_articles_search_doc on public.help_articles;
create trigger help_articles_search_doc before insert or update on public.help_articles
  for each row execute function public.help_articles_search_doc();

create index if not exists help_articles_search_idx on public.help_articles using gin (search_doc);
create index if not exists help_articles_sort_idx on public.help_articles (sort, title);

alter table public.help_articles enable row level security;

drop policy if exists "help_articles read" on public.help_articles;
create policy "help_articles read" on public.help_articles
  for select to anon, authenticated using (active or public.caller_is_admin());

drop policy if exists "help_articles admin insert" on public.help_articles;
create policy "help_articles admin insert" on public.help_articles
  for insert to authenticated with check (public.caller_is_admin());

drop policy if exists "help_articles admin update" on public.help_articles;
create policy "help_articles admin update" on public.help_articles
  for update to authenticated using (public.caller_is_admin()) with check (public.caller_is_admin());

drop policy if exists "help_articles admin delete" on public.help_articles;
create policy "help_articles admin delete" on public.help_articles
  for delete to authenticated using (public.caller_is_admin());

grant select on public.help_articles to anon, authenticated;
grant insert, update, delete on public.help_articles to authenticated;

-- ---------------------------------------------------------------------------
-- help_search: the articles that best answer p_query for p_audience.
--
-- Audiences: a rider (or anyone signed out) sees 'all' and 'rider' articles;
-- a partner also sees 'partner' ones (every partner can book rides too); an
-- admin sees everything. The score adds
--   * ts_rank_cd of the query's words OR-ed together (a natural question
--     never has every word in one article, so an AND query finds nothing),
--   * a bonus when every word matches (websearch syntax),
--   * the best trigram similarity of the whole question to the title or a
--     variant, which catches short questions and misspellings,
--   * for each word of the query, its best trigram likeness to a keyword or
--     a word of the title and variants, so a misspelt word ("walet",
--     "cancle") still counts.
-- SECURITY INVOKER: it reads through the table's own RLS.
-- ---------------------------------------------------------------------------
create or replace function public.help_search(p_query text, p_audience text default 'rider', p_limit int default 5)
returns table (
  id uuid,
  title text,
  answer text,
  action_label text,
  action_route text,
  category text,
  score real
)
language sql
stable
security invoker
set search_path = public, extensions
as $$
  with q as (
    select left(btrim(lower(coalesce(p_query, ''))), 500) as raw,
           coalesce(nullif(lower(btrim(p_audience)), ''), 'rider') as aud
  ), parts as (
    select q.raw, q.aud,
           to_tsvector('english'::regconfig, q.raw) as v,
           websearch_to_tsquery('english'::regconfig, q.raw) as q_all,
           -- The words worth a fuzzy match: four letters or more, and not an
           -- English stop word ("what", "where", …).
           array(select w from regexp_split_to_table(q.raw, '[^[:alnum:]]+') w
                  where length(w) >= 4 and to_tsvector('english'::regconfig, w) <> ''::tsvector) as words
      from q
  ), qq as (
    select parts.*,
           case when v = ''::tsvector then null
                else array_to_string(array(select quote_literal(l) from unnest(tsvector_to_array(v)) l), ' | ')::tsquery
           end as q_any
      from parts
  ), scored as (
    select a.id, a.title, a.answer, a.action_label, a.action_route, a.category, a.sort,
           coalesce(ts_rank_cd(a.search_doc, qq.q_any, 1), 0) as fts,
           case when qq.q_all is not null and numnode(qq.q_all) > 0 and a.search_doc @@ qq.q_all then 1 else 0 end as all_words,
           greatest(
             similarity(qq.raw, lower(a.title)),
             coalesce((select max(similarity(qq.raw, lower(v))) from unnest(a.question_variants) v), 0)
           ) as trigram,
           -- Each query word's best likeness to a keyword or to a word of the
           -- title and variants, summed over the words that come close.
           coalesce((select sum(b) from (
             select greatest(
                      coalesce((select max(similarity(w, lower(k))) from unnest(a.keywords) k), 0),
                      word_similarity(w, lower(a.title || ' ' || array_to_string(a.question_variants, ' ')))
                    ) as b
               from unnest(qq.words) w
           ) x where b >= 0.4), 0) as fuzzy
      from public.help_articles a, qq
     where a.active
       and qq.raw <> ''
       and (a.audience = 'all'
            or a.audience = qq.aud
            or qq.aud = 'admin'
            or (qq.aud = 'partner' and a.audience = 'rider')
            or (qq.aud = 'all' and a.audience = 'rider'))
  )
  select s.id, s.title, s.answer, s.action_label, s.action_route, s.category,
         (s.fts + 0.15 * s.all_words + s.trigram + 0.4 * s.fuzzy)::real as score
    from scored s
   where s.fts > 0 or s.trigram >= 0.3 or s.fuzzy > 0
   order by score desc, s.sort, s.title
   limit greatest(1, least(coalesce(p_limit, 5), 20));
$$;

grant execute on function public.help_search(text, text, int) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- help_questions: what was asked, and whether the answer helped.
-- ---------------------------------------------------------------------------
create table if not exists public.help_questions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  question text not null check (length(btrim(question)) between 1 and 500),
  -- The article that answered it; null when nothing did.
  matched_article_id uuid references public.help_articles(id) on delete set null,
  helpful boolean,
  created_at timestamptz not null default now()
);

create index if not exists help_questions_created_idx on public.help_questions (created_at desc);
create index if not exists help_questions_user_idx on public.help_questions (user_id, created_at desc);

alter table public.help_questions enable row level security;

drop policy if exists "help_questions own insert" on public.help_questions;
create policy "help_questions own insert" on public.help_questions
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists "help_questions own or admin read" on public.help_questions;
create policy "help_questions own or admin read" on public.help_questions
  for select to authenticated using (user_id = auth.uid() or public.caller_is_admin());

-- Only `helpful` is granted for update, so a question can't be rewritten.
drop policy if exists "help_questions own feedback" on public.help_questions;
create policy "help_questions own feedback" on public.help_questions
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "help_questions admin delete" on public.help_questions;
create policy "help_questions admin delete" on public.help_questions
  for delete to authenticated using (public.caller_is_admin());

-- Supabase's default privileges grant every table to anon and authenticated;
-- take back what this table must not allow before granting what it does.
revoke all on public.help_questions from anon;
revoke update on public.help_questions from authenticated;
grant select, insert, delete on public.help_questions to authenticated;
grant update (helpful) on public.help_questions to authenticated;

-- ---------------------------------------------------------------------------
-- Seed. Generated from assets/help/help_articles.json by
-- `dart run scripts/gen_help_kb.dart`; edit the JSON, not this block.
-- An id already present is left alone, so an admin's edits are never undone.
-- ---------------------------------------------------------------------------
-- BEGIN help_articles seed
insert into public.help_articles
  (id, title, question_variants, answer, keywords, audience, category, action_label, action_route, sort)
values
  ('68656c70-0000-4000-8000-000000000001', 'How do I sign up?',
   array['How do I create an account?', 'I''m new, how do I register?', 'How to daftar akaun?']::text[],
   'Enter your mobile number on the first screen and tap Sign up & send code. We text you a 6-digit code; type it in, then choose a 6-digit sign-in PIN. You can add a friend''s referral code on the same step.

If the operator has paused new sign-ups, a number with no account is told so and cannot register yet; existing accounts can still sign in.',
   array['sign up', 'register', 'registration', 'account', 'new', 'otp', 'daftar', 'akaun', 'pendaftaran']::text[],
   'all', 'Getting started', null, null, 10),
  ('68656c70-0000-4000-8000-000000000002', 'How do I sign in?',
   array['How do I log in?', 'Login with my phone number', 'Cara log masuk']::text[],
   'Enter your mobile number. If you already have an account, type your 6-digit PIN; no SMS is needed, and the same PIN works on any device. After 5 wrong PINs, sign-in is locked for 15 minutes.',
   array['sign in', 'login', 'log in', 'pin', 'phone', 'masuk', 'log masuk', 'kata laluan']::text[],
   'all', 'Getting started', null, null, 20),
  ('68656c70-0000-4000-8000-000000000003', 'I forgot my PIN',
   array['Forgot PIN', 'How do I reset my password?', 'I can''t remember my PIN', 'Lupa PIN']::text[],
   'On the PIN screen tap Forgot PIN? Verify by SMS. We text a code to your number; enter it and choose a new PIN.

Already signed in? Go to Settings → Change sign-in PIN and choose Forgot PIN? there: the code goes to your account''s own number.',
   array['forgot', 'reset', 'pin', 'password', 'lupa', 'kata laluan', 'sms', 'code']::text[],
   'all', 'Account & security', 'Change sign-in PIN', '/account/settings/pin', 30),
  ('68656c70-0000-4000-8000-000000000004', 'How do I change my PIN?',
   array['Change sign-in PIN', 'Update my password', 'Tukar PIN']::text[],
   'Go to Settings → Change sign-in PIN. Enter your current PIN, choose a new 6-digit PIN and type it again. The new PIN works straight away in both GET.ride apps.',
   array['change', 'pin', 'password', 'update', 'tukar', 'kata laluan', 'security']::text[],
   'all', 'Account & security', 'Change sign-in PIN', '/account/settings/pin', 40),
  ('68656c70-0000-4000-8000-000000000005', 'I''m not getting the SMS code',
   array['OTP not received', 'Sign-in code not arriving', 'No SMS code', 'Kod SMS tak sampai']::text[],
   'Check the number and country code are right, wait a minute, then tap Resend code. Make sure your phone has signal and is not blocking messages from unknown senders. If it still does not arrive, the Connection diagnostics button on the phone-number screen checks the connection and can send a test code.',
   array['otp', 'sms', 'code', 'not received', 'resend', 'kod', 'tak sampai', 'verification']::text[],
   'all', 'Getting started', null, null, 50),
  ('68656c70-0000-4000-8000-000000000006', 'How do I change my phone number?',
   array['Change mobile number', 'I have a new phone number', 'Tukar nombor telefon']::text[],
   'Go to Settings → Change phone number and enter the new number. We text a code to it; the change takes effect once you enter the code. Your sign-in PIN stays the same. A number that already belongs to another account cannot be used.',
   array['phone', 'number', 'mobile', 'change', 'nombor', 'telefon', 'tukar']::text[],
   'all', 'Account & security', 'Change phone number', '/account/settings/phone', 60),
  ('68656c70-0000-4000-8000-000000000007', 'How do I change my name or profile photo?',
   array['Edit my profile', 'Add a profile picture', 'Update my name', 'Tukar gambar profil']::text[],
   'Open Account → Edit profile (or tap your name at the top of the menu). You can change your name and email and take or choose a profile photo. Drivers see your photo when they pick you up.',
   array['profile', 'photo', 'picture', 'avatar', 'name', 'edit', 'gambar', 'nama', 'profil']::text[],
   'all', 'Account & security', 'Edit profile', '/account/edit', 70),
  ('68656c70-0000-4000-8000-000000000008', 'How do I switch to dark mode?',
   array['Change theme', 'Light mode', 'Dark theme', 'Mod gelap']::text[],
   'Go to Settings → Appearance and choose Light, Dark or System. System follows your phone''s setting.',
   array['dark', 'light', 'theme', 'appearance', 'mode', 'gelap', 'cerah', 'tema']::text[],
   'all', 'Account & security', 'Open Settings', '/account/settings', 80),
  ('68656c70-0000-4000-8000-000000000009', 'What do the tabs do?',
   array['How do I use the app?', 'Where is everything?', 'App guide']::text[],
   'Ride books a trip, Trips lists your history, Wallet holds your balances, Drive is for partners, and Account has your profile, safety and settings. The menu button opens the side menu with the same pages. Account → User guide explains every part of the app.',
   array['tabs', 'menu', 'guide', 'navigation', 'how', 'panduan', 'help']::text[],
   'all', 'Getting started', 'Open the user guide', '/account/guide', 90),
  ('68656c70-0000-4000-8000-000000000010', 'How do I book a ride?',
   array['Book a car', 'Request a ride', 'How to order a taxi?', 'Macam mana nak tempah kereta?']::text[],
   'On Ride, the pickup is your current location. Tap Where to?, search for your destination, pick a recent or saved place, or choose on the map. Pick a service, pay by cash or GET.wallet, add a note for the driver if you like, and tap Find a driver. Nearby drivers are asked straight away; a request nobody accepts expires after 7 minutes.',
   array['book', 'ride', 'request', 'order', 'taxi', 'car', 'tempah', 'kereta', 'teksi', 'pesan']::text[],
   'all', 'Booking', 'Book a ride', '/', 100),
  ('68656c70-0000-4000-8000-000000000011', 'How is the fare calculated?',
   array['How much will my ride cost?', 'Why is the price so high?', 'Fare estimate', 'Berapa tambang?']::text[],
   'The fare is estimated from the route''s distance and time, using live traffic where it is available, and priced on the service you pick. Estimated tolls are shown separately and are not included in the fare. Where offers are allowed you can set your own fare before booking (from 70% to 400% of the recommended fare).',
   array['fare', 'price', 'cost', 'estimate', 'how much', 'toll', 'tambang', 'harga', 'caj', 'tol']::text[],
   'all', 'Booking', null, null, 110),
  ('68656c70-0000-4000-8000-000000000012', 'Can I offer my own fare?',
   array['Set my own price', 'Offer your fare', 'Bidding', 'Can I bargain the price?', 'Tawar harga']::text[],
   'Where offers are allowed in your area, the booking sheet shows the recommended fare with − and + buttons, and you can type your own amount from 70% to 400% of it. Drivers may also send you a counter-offer while you wait; accept it, decline it, or raise your fare. Only one driver''s offer stands at a time.',
   array['offer', 'fare', 'bid', 'bidding', 'offerme', 'price', 'bargain', 'tawar', 'tambang', 'harga']::text[],
   'rider', 'Booking', 'Book a ride', '/', 120),
  ('68656c70-0000-4000-8000-000000000013', 'How do I raise my fare while waiting?',
   array['No driver is accepting', 'Nobody accepts my ride', 'Increase the fare', 'Naikkan tambang']::text[],
   'While your request is still looking for a driver, use the raise buttons (+RM1, +RM5 or +RM10) on the ride screen. A raise can take the fare up to 4 times the first quote; it clears any standing driver offer and alerts drivers again. If nobody has accepted after a while the app offers to raise the fare for you.',
   array['raise', 'increase', 'fare', 'no driver', 'waiting', 'naik', 'tambang', 'tiada pemandu']::text[],
   'rider', 'Booking', null, null, 130),
  ('68656c70-0000-4000-8000-000000000014', 'A driver offered a different price',
   array['Accept a driver''s offer', 'Decline an offer', 'Counter offer from driver']::text[],
   'A driver''s counter-offer appears as a card on the ride screen with their car and rating. Accept to book that driver at their price, or Decline to keep waiting at your fare. An offer stands for 45 seconds; if a newer offer replaces it, only the one shown can be accepted.',
   array['offer', 'counter', 'accept', 'decline', 'driver', 'price', 'tawaran', 'terima', 'tolak']::text[],
   'rider', 'Booking', null, null, 140),
  ('68656c70-0000-4000-8000-000000000015', 'Can I add stops on the way?',
   array['Multiple destinations', 'Add a stop', 'Multi-stop ride', 'Singgah']::text[],
   'Yes. On the booking sheet tap Add another stop. You can add up to 4 stops between the pickup and the destination; they are visited in order, and the route and the fare go through them. The driver sees every stop.',
   array['stop', 'stops', 'multi', 'multiple', 'destination', 'waypoint', 'singgah', 'berhenti']::text[],
   'rider', 'Booking', 'Book a ride', '/', 150),
  ('68656c70-0000-4000-8000-000000000016', 'How do I book a ride for someone else?',
   array['Book for a friend', 'Book for my parents', 'Ride for another person', 'Tempah untuk orang lain']::text[],
   'On the booking sheet choose Book for someone else and enter the passenger''s name and phone number, or Choose from contacts. You can book any number of rides for other people, one per passenger, as well as your own. Share the ride link with them so they can follow the car and see the trip code.',
   array['someone else', 'other person', 'friend', 'family', 'book for', 'passenger', 'orang lain', 'keluarga']::text[],
   'rider', 'Booking', 'Book a ride', '/', 160),
  ('68656c70-0000-4000-8000-000000000017', 'How do I save Home and Work?',
   array['Saved places', 'Save an address', 'Favourite places', 'Simpan alamat rumah']::text[],
   'On Where to?, open the Saved tab. Set Home and Work, and add any other places you go to often, each with an entrance to wait at. Saved places are kept on your account and only you can see them. You need to be signed in.',
   array['saved', 'home', 'work', 'favourite', 'place', 'address', 'rumah', 'pejabat', 'alamat', 'simpan']::text[],
   'rider', 'Booking', 'Book a ride', '/', 170),
  ('68656c70-0000-4000-8000-000000000018', 'Can I pay by cash or wallet?',
   array['Payment methods', 'How do I pay?', 'Pay with GET.wallet', 'Bayar tunai']::text[],
   'Choose cash or GET.wallet on the booking sheet before you book. If you have GET.coin, you can also switch on GET.coin to take part of the fare off at drop-off; you pay the rest as usual.',
   array['pay', 'payment', 'cash', 'wallet', 'method', 'bayar', 'tunai', 'pembayaran']::text[],
   'rider', 'Payments & wallet', null, null, 180),
  ('68656c70-0000-4000-8000-000000000019', 'Do promo codes work?',
   array['Got promo code', 'Discount code', 'Voucher', 'Kod promo']::text[],
   'The booking sheet has a promo code box, but no promotions are running at the moment, so codes are not accepted. Ride rewards in GET.coin and referral bonuses are the current ways to save.',
   array['promo', 'discount', 'voucher', 'coupon', 'code', 'diskaun', 'baucar']::text[],
   'rider', 'Payments & wallet', null, null, 190),
  ('68656c70-0000-4000-8000-000000000020', 'GET.ride is unavailable here',
   array['Service not available in my area', 'Why can''t I book from here?', 'We don''t pick up there yet', 'Tidak tersedia']::text[],
   'GET.ride only runs inside the regions the operator has set up, and a region can be paused. If your pickup, a stop or the destination is outside them, the app says so and offers to change that point. Try a nearby main road or remove the stop. If you see Service Not Available at sign-in, your network has been blocked; try another connection or contact support.',
   array['unavailable', 'not available', 'area', 'region', 'coverage', 'service area', 'kawasan', 'tiada perkhidmatan']::text[],
   'all', 'Booking', null, null, 200),
  ('68656c70-0000-4000-8000-000000000021', 'Can I request a child seat or bring a pet?',
   array['Ride options', 'Pet with me', 'Child safety seat', 'More passengers']::text[],
   'Open Options on the booking sheet to ask for a child safety seat, say you are travelling with a pet, or that you are more passengers than a standard car seats. Add anything else in the note for your driver.',
   array['child seat', 'pet', 'options', 'passengers', 'luggage', 'kerusi kanak', 'haiwan']::text[],
   'rider', 'Booking', null, null, 210),
  ('68656c70-0000-4000-8000-000000000022', 'How do I track my driver?',
   array['Where is my driver?', 'Ride tracking', 'Driver location']::text[],
   'Once a driver accepts, the ride screen shows their name, photo, car, plate and rating, and moves their car on the map as they drive to you. It updates live; if you close the app, opening it again returns you to the ride.',
   array['track', 'driver', 'location', 'map', 'where', 'pemandu', 'lokasi', 'jejak']::text[],
   'rider', 'During the ride', null, null, 220),
  ('68656c70-0000-4000-8000-000000000023', 'What is the trip code?',
   array['Trip code', 'OTP for the driver', 'Verification code at pickup', 'Kod perjalanan']::text[],
   'The trip code is shown on your ride screen until the trip starts. Tell it to the driver when they arrive: they enter it to confirm they have the right passenger before starting the trip. Never share it before the car arrives.',
   array['trip code', 'code', 'otp', 'pickup', 'verify', 'kod']::text[],
   'all', 'During the ride', null, null, 230),
  ('68656c70-0000-4000-8000-000000000024', 'How do I contact my driver?',
   array['Call the driver', 'Message my driver', 'Chat with driver', 'Hubungi pemandu']::text[],
   'Use Call or Message on the ride screen once a driver has accepted. Call opens your phone''s dialler and Message opens your SMS app with the driver''s number. There is no separate in-app chat with the driver.',
   array['call', 'message', 'chat', 'contact', 'driver', 'sms', 'hubungi', 'pemandu', 'telefon']::text[],
   'rider', 'During the ride', null, null, 240),
  ('68656c70-0000-4000-8000-000000000025', 'How do I cancel a ride?',
   array['Cancel my booking', 'Cancel request', 'I want to cancel', 'Batal tempahan']::text[],
   'Before the trip starts, tap Cancel ride on the ride screen and pick a reason; it is cancelled straight away. Once you are on the trip, the button becomes Request cancellation: the driver is asked to confirm, and the screen shows Cancellation requested until they do.',
   array['cancel', 'cancellation', 'batal', 'pembatalan', 'stop', 'booking']::text[],
   'rider', 'During the ride', null, null, 250),
  ('68656c70-0000-4000-8000-000000000026', 'My driver cancelled',
   array['Driver cancelled my ride', 'Why did the driver cancel?', 'Pemandu batal']::text[],
   'A driver can only cancel before you are on board, and gives a reason, which the ride screen shows. You are not charged for a cancelled ride. You can book another ride from the map straight away.',
   array['driver cancelled', 'cancel', 'no show', 'batal', 'pemandu']::text[],
   'rider', 'During the ride', 'Book a ride', '/', 260),
  ('68656c70-0000-4000-8000-000000000027', 'How do I share my ride with family?',
   array['Share my trip', 'Send my live location', 'Share ride link', 'Kongsi perjalanan']::text[],
   'Tap the share button on the ride screen. It sends a getride.my link that anyone can open, with or without an account, to follow the car on a map. The link shows the driver, the car and the route, but never phone numbers.',
   array['share', 'link', 'family', 'live location', 'follow', 'kongsi', 'keluarga', 'pautan']::text[],
   'rider', 'During the ride', null, null, 270),
  ('68656c70-0000-4000-8000-000000000028', 'What does SOS do?',
   array['Emergency during a ride', 'I feel unsafe', 'Call police', 'Kecemasan']::text[],
   'During a ride, tap SOS · Emergency. You can call 999 (police, ambulance and fire) or alert your emergency contacts by SMS with your location, the driver and the car. Outside a ride, Account → Safety → Emergency SOS messages your contacts with a map link to where you are.',
   array['sos', 'emergency', 'unsafe', 'police', '999', 'help', 'kecemasan', 'polis', 'bahaya']::text[],
   'all', 'Safety', 'Open Safety', '/account/safety', 280),
  ('68656c70-0000-4000-8000-000000000029', 'How do I add emergency contacts?',
   array['Trusted contacts', 'Emergency contact', 'Kenalan kecemasan']::text[],
   'Go to Account → Emergency contacts and add up to 5 people, typed in or picked from your contacts. They are who Emergency SOS messages. Add at least one before you need SOS.',
   array['emergency contact', 'trusted', 'contact', 'family', 'kenalan', 'kecemasan']::text[],
   'all', 'Safety', 'Emergency contacts', '/account/emergency', 290),
  ('68656c70-0000-4000-8000-000000000030', 'What is VoiceProtection?',
   array['Trip audio recording', 'Is my ride recorded?', 'Rakaman suara']::text[],
   'VoiceProtection is a switch in Settings and Safety. With it on, the driver''s phone records trip audio from Start trip to the end of the ride. The recording stays on that phone, is never played back in the app and is deleted after 24 hours. It only reaches our team if a ride is reported and a support agent asks for it. Phones only.',
   array['voice', 'recording', 'audio', 'record', 'privacy', 'voiceprotection', 'rakaman', 'suara']::text[],
   'all', 'Safety', 'Open Safety', '/account/safety', 300),
  ('68656c70-0000-4000-8000-000000000031', 'Where are my past trips and receipts?',
   array['Trip history', 'Get a receipt', 'Download invoice', 'Resit perjalanan']::text[],
   'Open Trips. Every ride you booked or drove is listed; tap a finished one for its receipt, with the booking number, route, times, driver and car, payment mode, the fare and any tolls or other charges. Print it, Share PDF or Copy it as text.',
   array['trips', 'history', 'receipt', 'invoice', 'past', 'pdf', 'resit', 'sejarah', 'perjalanan']::text[],
   'all', 'Trips', 'Open Trips', '/trips', 310),
  ('68656c70-0000-4000-8000-000000000032', 'Why was I charged tolls?',
   array['Extra charges on my receipt', 'Toll charges', 'Other charges', 'Caj tol']::text[],
   'Tolls and other charges are declared by the driver when the trip ends and are listed on their own lines of your receipt, separate from the trip fare. If something looks wrong, open the trip and contact support with the booking number.',
   array['toll', 'charges', 'extra', 'receipt', 'other charges', 'tol', 'caj']::text[],
   'rider', 'Trips', 'Open Trips', '/trips', 320),
  ('68656c70-0000-4000-8000-000000000033', 'How do I earn GET.coin from rides?',
   array['Ride rewards', 'Coins for my trip', 'Ganjaran']::text[],
   'A completed trip can earn GET.coin, priced on the ride''s fare. The reward is claimed on the ride screen when the trip finishes, or from the receipt if the trip finished while the app was closed. Each ride pays its reward once.',
   array['reward', 'coin', 'get.coin', 'earn', 'points', 'ganjaran', 'syiling']::text[],
   'rider', 'Payments & wallet', 'Open Trips', '/trips', 330),
  ('68656c70-0000-4000-8000-000000000034', 'What are GET.wallet, GET.credit and GET.coin?',
   array['Wallet types', 'Difference between wallet and credit', 'Dompet']::text[],
   'GET.wallet is your main balance, used as a rider and as a driver. GET.credit is for partners: it pays ride commission and in-app services and is recharged from GET.wallet; it can go below zero when commission is owed. GET.coin is a reward coin you can use on fares and QR payments, trade against GET.wallet or send to others.',
   array['wallet', 'credit', 'coin', 'balance', 'get.wallet', 'get.credit', 'get.coin', 'dompet', 'baki']::text[],
   'all', 'Payments & wallet', 'Open Wallet', '/wallet', 340),
  ('68656c70-0000-4000-8000-000000000035', 'How do I top up my wallet?',
   array['Add money to GET.wallet', 'Reload wallet', 'Top up', 'Tambah nilai']::text[],
   'In-app top-up is not available yet: no payment gateway is connected, so GET.wallet cannot be reloaded from the app. Contact support if you need funds added. GET.coin can be earned from rides and referrals in the meantime.',
   array['top up', 'topup', 'reload', 'add money', 'fund', 'deposit', 'tambah nilai', 'isi', 'dompet']::text[],
   'all', 'Payments & wallet', 'Chat with support', '/account/support', 350),
  ('68656c70-0000-4000-8000-000000000036', 'How do I send GET.coin to someone?',
   array['Transfer coins', 'Send coins to a friend', 'Pindah syiling']::text[],
   'Open Wallet → GET.coin: buy, sell, send, choose Send and enter the other person''s phone number or wallet ID and the amount. They get a request to accept; nothing moves until they do, and the request expires after 15 minutes. You can withdraw it while you wait. For privacy you only see a short form of their name.',
   array['send', 'transfer', 'coin', 'get.coin', 'friend', 'pindah', 'hantar', 'syiling']::text[],
   'all', 'Payments & wallet', 'Send GET.coin', '/wallet/trade', 360),
  ('68656c70-0000-4000-8000-000000000037', 'Someone sent me GET.coin',
   array['Accept a coin transfer', 'Incoming transfer', 'Decline coins']::text[],
   'An approval card appears over whatever screen you are on, naming the sender and the amount. Accept to receive the coins, or decline. A request you leave expires after 15 minutes.',
   array['receive', 'incoming', 'transfer', 'accept', 'coin', 'terima']::text[],
   'all', 'Payments & wallet', 'Open Wallet', '/wallet', 370),
  ('68656c70-0000-4000-8000-000000000038', 'How do I buy or sell GET.coin?',
   array['Trade coins', 'Coin rate', 'Convert coins to cash', 'Jual syiling']::text[],
   'Open Wallet → GET.coin: buy, sell, send. Buying takes RM from GET.wallet and selling puts it back. The buy and sell prices are shown before you confirm and are set by the operator; the trade settles at the server''s price.',
   array['buy', 'sell', 'trade', 'coin', 'rate', 'price', 'convert', 'beli', 'jual', 'syiling']::text[],
   'all', 'Payments & wallet', 'Trade GET.coin', '/wallet/trade', 380),
  ('68656c70-0000-4000-8000-000000000039', 'How do I pay with a QR code?',
   array['Scan and pay', 'QR payment', 'Pay a merchant', 'Bayar QR']::text[],
   'Open Wallet → Scan & Pay and point the camera at the code (or paste it). A merchant''s code is paid from GET.wallet, optionally part-paid with GET.coin. A GET.ride account''s code opens Send, addressed to that account.',
   array['qr', 'scan', 'pay', 'merchant', 'duitnow', 'imbas', 'bayar']::text[],
   'all', 'Payments & wallet', 'Scan & Pay', '/wallet/scan', 390),
  ('68656c70-0000-4000-8000-000000000040', 'How do I receive money with my QR?',
   array['Show my QR code', 'Receive payment', 'My wallet ID']::text[],
   'Open Wallet → Receive to show your code, optionally with a fixed amount (valid for 60 seconds). GET.coin QR shows the same code with your wallet ID.',
   array['receive', 'qr', 'my code', 'wallet id', 'terima']::text[],
   'all', 'Payments & wallet', 'Show my QR', '/wallet/receive', 400),
  ('68656c70-0000-4000-8000-000000000041', 'Where is my wallet history?',
   array['Transaction history', 'Wallet statement', 'Penyata dompet']::text[],
   'Open Wallet → See all. History pages through your transactions a month at a time, with tabs per wallet (GET.credit for partners), category chips such as Ride, Reward, Referral and Transfer, and details for each row.',
   array['history', 'transactions', 'statement', 'wallet', 'sejarah', 'penyata', 'transaksi']::text[],
   'all', 'Payments & wallet', 'Wallet history', '/wallet/history', 410),
  ('68656c70-0000-4000-8000-000000000042', 'How do referrals work?',
   array['Invite friends', 'Referral code', 'Get coins for inviting', 'Kod rujukan']::text[],
   'Open Account → Invite friends for your code and invite link. A friend who signs up as a new account and enters your code on the set-PIN step earns bonus GET.coin for both of you. A code is only accepted by an account created in the last 7 days.',
   array['referral', 'invite', 'friend', 'code', 'bonus', 'rujukan', 'jemput', 'kawan']::text[],
   'all', 'Payments & wallet', 'Invite friends', '/account/referral', 420),
  ('68656c70-0000-4000-8000-000000000043', 'How do I become a driver?',
   array['Become a partner', 'Drive with GET.ride', 'Sign up as driver', 'Jadi pemandu']::text[],
   'Open the Drive tab and tap Get started. The application has six steps: profile photo, ID number, address, service area, partner type, then the documents required for those types and areas. It resumes where you left off. Once submitted, an admin reviews it; you can take jobs once your account is approved.',
   array['driver', 'partner', 'become', 'apply', 'onboarding', 'pemandu', 'rakan', 'mohon']::text[],
   'all', 'Driving', 'Start your application', '/drive/onboarding', 430),
  ('68656c70-0000-4000-8000-000000000044', 'My partner application was rejected',
   array['Application not approved', 'Why was I rejected?', 'Resubmit my application', 'Permohonan ditolak']::text[],
   'The Drive tab shows Application not approved with the admin''s reason. Fix what they pointed out (usually a document), then tap Send for review again. You can also contact support from that screen.',
   array['rejected', 'not approved', 'resubmit', 'reason', 'ditolak', 'mohon semula']::text[],
   'partner', 'Driving', 'Open Drive', '/drive', 440),
  ('68656c70-0000-4000-8000-000000000045', 'How long does approval take?',
   array['Waiting for approval', 'Application under review', 'When can I drive?']::text[],
   'Your application is with an admin for review; the Drive tab shows Waiting for approval until they decide, and you are notified when they do. If it says Documents needed, an admin wants some documents updated: upload any that are rejected or expired.',
   array['approval', 'review', 'pending', 'waiting', 'kelulusan', 'lulus']::text[],
   'partner', 'Driving', 'Open Drive', '/drive', 450),
  ('68656c70-0000-4000-8000-000000000046', 'How do I upload or renew my documents?',
   array['Update documents', 'My document expired', 'Upload licence', 'Muat naik dokumen']::text[],
   'Open Drive (or the driver menu → Documents). Each required document shows its status; upload a new photo of any that is rejected or expired. Photos are checked automatically where possible and then reviewed by an admin.',
   array['document', 'documents', 'upload', 'expired', 'licence', 'renew', 'dokumen', 'lesen', 'tamat']::text[],
   'partner', 'Driving', 'Update documents', '/drive/onboarding', 460),
  ('68656c70-0000-4000-8000-000000000047', 'How do I register my vehicle?',
   array['Add a car', 'Vehicle registration', 'My vehicles', 'Daftar kenderaan']::text[],
   'Go to Drive → My vehicles → Add vehicle. Enter the plate, make and model, year and colour, add four photos and the owner (or choose my own vehicle), then upload the vehicle''s documents. It is reviewed by an admin. A plate already registered to another account cannot be added.',
   array['vehicle', 'car', 'register', 'plate', 'add', 'kenderaan', 'kereta', 'daftar', 'nombor plat']::text[],
   'partner', 'Driving', 'Add a vehicle', '/drive/vehicles/new', 470),
  ('68656c70-0000-4000-8000-000000000048', 'How do I go online and take requests?',
   array['Start receiving jobs', 'Go online', 'Accept ride requests', 'Terima tempahan']::text[],
   'On the Drive tab, switch yourself online. Open requests are listed nearest first; accept one to take it. Auto-accept takes new requests for you, and Allow OfferMe requests lets you send your own price where the rider allows it. Your documents are checked before you go online.',
   array['online', 'requests', 'jobs', 'accept', 'queue', 'auto-accept', 'dalam talian', 'terima']::text[],
   'partner', 'Driving', 'Open Drive', '/drive', 480),
  ('68656c70-0000-4000-8000-000000000049', 'How do I offer a price to a rider?',
   array['Counter offer', 'OfferMe', 'Bid on a request']::text[],
   'On a request open to offers, tap Offer price and pick a preset (+20%, +30% or +50%). The rider has up to 45 seconds to answer; you see whether you won, were outbid, declined, or the rider raised the fare. Turn off Allow OfferMe requests to take riders'' prices only.',
   array['offer', 'bid', 'offerme', 'price', 'counter', 'tawar']::text[],
   'partner', 'Driving', null, null, 490),
  ('68656c70-0000-4000-8000-000000000050', 'How do I complete a trip?',
   array['Start the trip', 'Arrived at pickup', 'End trip', 'Tamat perjalanan']::text[],
   'On the trip screen: Navigate opens your navigation app, then mark Arrived, enter the rider''s trip code, Start the trip and Complete it at the drop-off, declaring any tolls or other charges. Commission is taken from GET.credit when the trip completes.',
   array['complete', 'start', 'arrived', 'trip', 'end', 'navigate', 'tamat', 'mula']::text[],
   'partner', 'Driving', null, null, 500),
  ('68656c70-0000-4000-8000-000000000051', 'Why was commission taken from GET.credit?',
   array['Commission', 'Negative credit balance', 'Recharge GET.credit', 'Komisen']::text[],
   'The platform''s commission is charged to GET.credit once per completed trip, at the rate the operator set for your area. GET.credit may go below zero when commission is owed. Recharge it from GET.wallet on the Wallet screen.',
   array['commission', 'credit', 'get.credit', 'negative', 'recharge', 'komisen', 'kredit']::text[],
   'partner', 'Payments & wallet', 'Open Wallet', '/wallet', 510),
  ('68656c70-0000-4000-8000-000000000052', 'What is destination mode?',
   array['Heading home', 'Only trips toward my destination', 'Mod destinasi']::text[],
   'While online on the Drive tab, set where you are heading and switch destination mode on. Requests that bring you at least 2 km closer are listed first and marked Toward your destination; auto-accept takes only those.',
   array['destination', 'home', 'heading', 'direction', 'destinasi', 'pulang']::text[],
   'partner', 'Driving', 'Open Drive', '/drive', 520),
  ('68656c70-0000-4000-8000-000000000053', 'How do shared vehicles work?',
   array['Co-driver', 'Hand back the car', 'Choose my vehicle']::text[],
   'A car can be driven by its owner and by drivers an admin adds. Choose the car on the Drive tab''s Vehicle card; only one driver can use it at a time. Tap Hand back when you finish so the next driver can take it.',
   array['shared', 'co-driver', 'hand back', 'vehicle', 'kongsi', 'kereta']::text[],
   'partner', 'Driving', 'Open Drive', '/drive', 530),
  ('68656c70-0000-4000-8000-000000000054', 'Which navigation app opens?',
   array['Use Waze', 'Google Maps', 'Change navigation app']::text[],
   'Settings → Navigation app lets you choose Google Maps, Waze or (on Apple devices) Apple Maps. The Navigate button on a trip opens the one you chose.',
   array['navigation', 'waze', 'google maps', 'apple maps', 'navigate', 'peta']::text[],
   'partner', 'Driving', 'Open Settings', '/account/settings', 540),
  ('68656c70-0000-4000-8000-000000000055', 'What is TEKSI mode?',
   array['Taxi mode', 'TEKSI driver', 'Switch between TEKSI and e-hailing', 'Mod teksi']::text[],
   'TEKSI is the metered taxi service; e-hailing takes ride requests from the app. A partner with both types picks one from Partner Mode in the menu. TEKSI opens your taxi driver permit, where the Meter Digital button starts the meter; your documents, vehicle and permit are checked first.',
   array['teksi', 'taxi', 'mode', 'e-hailing', 'ehailing', 'partner mode', 'teksi']::text[],
   'partner', 'TEKSI & meter', 'Driver permit', '/drive/permit', 550),
  ('68656c70-0000-4000-8000-000000000056', 'How does Meter Digital work?',
   array['Taxi meter', 'Start the meter', 'Meter not counting', 'Meter teksi']::text[],
   'Meter Digital bills street hires on the operator''s rate card. It measures the trip with the car''s OBD-II reader when one is linked, and falls back to GPS where the rate card allows. Press START when the passenger is in, PAUSE / RESUME as needed, and END at the destination. DAY / NIGHT and EXTRA keys apply the night rate and extra charges. A running hire cannot be left until it is ended.',
   array['meter', 'taxi', 'start', 'end', 'fare', 'gps', 'rate card', 'teksi', 'meter digital']::text[],
   'partner', 'TEKSI & meter', 'Open the meter', '/meter', 560),
  ('68656c70-0000-4000-8000-000000000057', 'What happens when I end a hire?',
   array['END button', 'Declare passengers and luggage', 'Airport surcharge']::text[],
   'END stops the fare at once. Then declare the passengers, luggage, tolls and other charges, and whether an airport was involved (which adds its surcharge). RESUME HIRE puts the passenger back and restarts from now. The hire is saved to the trip log with a receipt you can print or copy.',
   array['end', 'hire', 'passengers', 'luggage', 'airport', 'surcharge', 'receipt', 'lapangan terbang']::text[],
   'partner', 'TEKSI & meter', 'Open the meter', '/meter', 570),
  ('68656c70-0000-4000-8000-000000000058', 'Why can''t I open the meter?',
   array['Meter Digital blocked', 'Permit check failed', 'Start pickup not working']::text[],
   'Before the meter opens, the app checks that your TEKSI documents are in order, that you have a vehicle, and that your taxi driver permit matches your IC, has not expired and belongs to the vehicle you are driving. The message says which check failed; update the document or choose the right vehicle.',
   array['meter', 'permit', 'blocked', 'check', 'expired', 'ic', 'permit teksi']::text[],
   'partner', 'TEKSI & meter', 'Driver permit', '/drive/permit', 580),
  ('68656c70-0000-4000-8000-000000000059', 'How do I connect an OBD-II reader?',
   array['OBD reader', 'ELM327', 'Connect the car', 'Bluetooth dongle']::text[],
   'From the meter''s reader button, open the OBD-II reader screen. Add a Wi-Fi reader by its address or scan for a Bluetooth LE reader (it will not appear in your phone''s own Bluetooth list), select it and connect. The link reconnects by itself. A browser cannot connect to a reader.',
   array['obd', 'obd-ii', 'elm327', 'reader', 'dongle', 'bluetooth', 'wifi', 'canbus']::text[],
   'partner', 'TEKSI & meter', 'OBD-II reader', '/meter/reader', 590),
  ('68656c70-0000-4000-8000-000000000060', 'What does Vehicle information show?',
   array['Fuel level', 'Check engine codes', 'Odometer reading']::text[],
   'With an OBD-II reader linked, Vehicle information shows the odometer, fuel level and an estimated range, the VIN and ECU identity, stored and pending trouble codes, readiness monitors and every parameter the car reports.',
   array['vehicle information', 'fuel', 'odometer', 'trouble codes', 'dtc', 'vin', 'minyak']::text[],
   'partner', 'TEKSI & meter', 'Vehicle information', '/meter/vehicle', 600),
  ('68656c70-0000-4000-8000-000000000061', 'How do I set up a receipt printer?',
   array['Thermal printer', 'Print receipts', 'Bluetooth printer', 'Pencetak resit']::text[],
   'From the meter''s printer button, add a Bluetooth LE printer found with the in-app scan, or a Wi-Fi printer by IP address (port 9100), choose the paper width (58 or 80 mm), select it and run a test print. Receipts then print straight to it.',
   array['printer', 'print', 'receipt', 'thermal', 'bluetooth', 'escpos', 'pencetak', 'cetak']::text[],
   'partner', 'TEKSI & meter', 'Receipt printer', '/meter/printer', 610),
  ('68656c70-0000-4000-8000-000000000062', 'Where is my taxi driver permit?',
   array['Driver permit', 'Permit expiry', 'Permit teksi']::text[],
   'TEKSI partners see their permit from Drive → the permit badge: the uploaded taxi driver permit, its review status and expiry (with a warning within 30 days). Upload a new one from your documents when it is renewed.',
   array['permit', 'driver permit', 'expiry', 'taxi permit', 'permit teksi', 'lesen']::text[],
   'partner', 'TEKSI & meter', 'Driver permit', '/drive/permit', 620),
  ('68656c70-0000-4000-8000-000000000063', 'How do I contact support?',
   array['Talk to a person', 'Customer service', 'Chat with support', 'Hubungi sokongan']::text[],
   'Open Help & support and tap Chat with us. Our team replies in the chat, and you can send photos or videos. Use Call support in the chat for an in-app voice call.',
   array['support', 'help', 'contact', 'chat', 'customer service', 'agent', 'complaint', 'sokongan', 'bantuan', 'aduan']::text[],
   'all', 'Support', 'Chat with support', '/account/support', 630),
  ('68656c70-0000-4000-8000-000000000064', 'How do I report a problem with a ride?',
   array['Complaint about a driver', 'Lost item', 'Report a trip', 'Barang tertinggal']::text[],
   'Open the trip from Trips to find its booking number, then start a chat in Help & support and tell us what happened. For a lost item, include what it is and where you sat. In an emergency, use SOS first.',
   array['report', 'problem', 'complaint', 'lost', 'item', 'driver', 'aduan', 'tertinggal', 'masalah']::text[],
   'all', 'Support', 'Chat with support', '/account/support', 640),
  ('68656c70-0000-4000-8000-000000000065', 'Will I get notifications?',
   array['Push notifications', 'Turn on alerts', 'Notifikasi']::text[],
   'On Android and iPhone the app sends push notifications for ride requests (partners), GET.coin transfers and updates from the operator. Allow notifications for GET.ride in your phone''s settings. Tapping one opens the right screen.',
   array['notification', 'push', 'alert', 'notifikasi', 'pemberitahuan']::text[],
   'all', 'Support', null, null, 650),
  ('68656c70-0000-4000-8000-000000000066', 'Can I order a TEKSI EV?',
   array['Buy an electric car', 'Book TEKSI EV', 'EV order']::text[],
   'Account → Book TEKSI EV walks you through choosing a model and specification, the order fee, owner, plate, financing, delivery advisor and delivery date. Nothing is charged in the app; payments are recorded by the back office. You can leave and resume the order later.',
   array['ev', 'electric', 'car', 'buy', 'order', 'kereta elektrik']::text[],
   'all', 'Getting started', 'Book TEKSI EV', '/ev', 660),
  ('68656c70-0000-4000-8000-000000000067', 'How do I add help articles?',
   array['Edit help assistant answers', 'Unanswered questions', 'Help articles admin']::text[],
   'Admin → Settings → Help articles lists every article. Create, edit, switch off or delete them, and set the audience and an optional in-app action. The Unanswered questions tab shows what people asked that nothing matched, or that they marked unhelpful; Create article from this starts a new article from the question.',
   array['help', 'articles', 'assistant', 'faq', 'unanswered', 'admin', 'knowledge']::text[],
   'admin', 'Admin', 'Help articles', '/admin/m/help-articles', 670),
  ('68656c70-0000-4000-8000-000000000068', 'How do I review partner documents?',
   array['Approve a driver', 'Document review queue', 'Reject a partner']::text[],
   'Admin → Documents is the review queue: open a document''s files and its automatic check, then approve or reject with a note. Admin → Partners sets a partner''s status; a rejection or block carries a reason the partner sees.',
   array['approve', 'reject', 'documents', 'partner', 'review', 'admin']::text[],
   'admin', 'Admin', 'Documents', '/admin/documents', 680),
  ('68656c70-0000-4000-8000-000000000069', 'How do I send a push notification to everyone?',
   array['Broadcast message', 'Notify all drivers', 'Push to users']::text[],
   'Admin → Push notifications sends a message to everyone, passengers or partners, and keeps a history of what was sent.',
   array['push', 'broadcast', 'notification', 'admin', 'message']::text[],
   'admin', 'Admin', 'Push notifications', '/admin/push', 690),
  ('68656c70-0000-4000-8000-000000000070', 'How do I delete my account?',
   array['Close my account', 'Remove my data', 'Padam akaun']::text[],
   'There is no delete button in the app. Ask in Help & support chat and our team will close your account. Settle any GET.wallet balance and finish any ride first, and partners should hand back any shared vehicle.',
   array['delete', 'close', 'remove', 'account', 'data', 'padam', 'tutup', 'akaun']::text[],
   'all', 'Account & security', 'Chat with support', '/account/support', 700)
on conflict (id) do nothing;
-- END help_articles seed

notify pgrst, 'reload schema';
