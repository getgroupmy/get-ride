-- ============================================================================
-- 0335 — Marketing SMS go only to people who said yes: the News and offers
-- switch (0333, profiles.news_offers, off until the person turns it on) now
-- covers the admin's marketing SMS as well as push broadcasts.
--
-- Version 20261102120000 (0335_marketing_sms_consent). Re-runnable:
-- functions "create or replace", triggers dropped first, the index "if not
-- exists". Stands on 0120 / 0183 / 0190 (the SMS queue, the gateway's claim
-- and its inbox), 0317 (family_phone_digits) and 0333 (news_offers,
-- store_review).
--
-- 1. marketing_sms_consent(phone) -> 'opted_in' | 'not_opted_in' |
--    'no_account': whether a live account (not deleted, not the store
--    review account) with that number has News and offers on. Numbers are
--    compared as digits with the country code (family_phone_digits: a
--    Malaysian 0... reads as 60...), helped by an index on profiles.
-- 2. The queue (sms_outbox), on the server, whatever path a row comes by
--    (the admin's page, a session key's test SMS, a definer function): a
--    marketing SMS to a number that has not opted in, or that has no
--    account, is refused before it is queued (MARKETING_NO_CONSENT, BEFORE
--    INSERT OR UPDATE OF channel, to_phone). Trip, safety, sign-in code,
--    support and ops SMS are not touched.
-- 3. The gateway (gateway_claim_for, 0190's, otherwise unchanged): a
--    marketing SMS still waiting when its number has since turned News and
--    offers off is failed ('No News and offers consent'), never sent.
-- 4. admin_queue_marketing_sms(phones, body): the admin's marketing send to
--    many numbers. Each distinct number is queued only when it opted in; the
--    answer says how many were queued and how many were left out, and why
--    (not opted in, no account, not a phone number). Same rights as queuing
--    an SMS on the page (caller_admin_can_write('sms_outbox')); logged in
--    admin_audit_log ('marketing_sms.queue', the counts only).
--    admin_marketing_sms_reach(): how many live accounts with a phone have
--    News and offers on, for the page (any admin).
-- 5. STOP: an SMS the gateway receives (sms_inbox, any path) that says
--    STOP, STOP ALL, UNSUBSCRIBE or BERHENTI (any case, punctuation
--    ignored) turns News and offers off for every live account with that
--    number, and fails that number's waiting marketing SMS ('Replied STOP').
--    The person can turn it on again in Settings > Notifications.
-- ============================================================================

-- ---- 1. Consent --------------------------------------------------------------------------------
create index if not exists profiles_phone_digits_idx
  on public.profiles (public.family_phone_digits(phone))
  where phone is not null;

create or replace function public.marketing_sms_consent(p_phone text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  with d as (select public.family_phone_digits(p_phone) as digits),
  live as (
    select p.news_offers
      from public.profiles p, d
     where d.digits is not null
       and public.family_phone_digits(p.phone) = d.digits
       and p.phone is not null
       and p.deleted_at is null
       and not p.store_review
  )
  select case
    when exists (select 1 from live where news_offers) then 'opted_in'
    when exists (select 1 from live) then 'not_opted_in'
    else 'no_account'
  end;
$$;
revoke execute on function public.marketing_sms_consent(text) from public, anon, authenticated;
grant execute on function public.marketing_sms_consent(text) to service_role;

-- ---- 2. The queue refuses marketing without consent ------------------------------------------------
create or replace function public.sms_outbox_marketing_consent()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v text;
begin
  if new.channel is distinct from 'marketing' then
    return new;
  end if;
  v := public.marketing_sms_consent(new.to_phone);
  if v = 'opted_in' then
    return new;
  end if;
  raise exception 'MARKETING_NO_CONSENT' using errcode = '42501',
    hint = case when v = 'no_account'
                then 'This number has no GET.ride account, so it can''t be sent marketing SMS.'
                else 'This number hasn''t turned on News and offers, so it can''t be sent marketing SMS.' end;
end;
$$;
revoke execute on function public.sms_outbox_marketing_consent() from public, anon, authenticated;

drop trigger if exists trg_sms_outbox_marketing_consent on public.sms_outbox;
create trigger trg_sms_outbox_marketing_consent
  before insert or update of channel, to_phone on public.sms_outbox
  for each row execute function public.sms_outbox_marketing_consent();

-- ---- 3. The gateway never sends one whose consent has gone -------------------------------------
-- As 0190, plus the marketing step before the claim.
create or replace function public.gateway_claim_for(p_dev uuid, p_limit integer)
returns setof public.sms_outbox
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.messaging_devices set last_seen_at = now() where id = p_dev;

  -- A sign-in code is good for the admin's minutes: one still waiting after
  -- that is failed, not sent.
  update public.sms_outbox
     set status = 'failed', error = 'expired before sending'
   where channel = 'otp' and status in ('queued', 'sending')
     and created_at < now() - make_interval(mins => coalesce(
           (select code_valid_minutes from public.sms_settings where id = 1), 5));

  -- A marketing SMS whose number turned News and offers off (or whose
  -- account went) while it waited is failed, not sent (0335).
  update public.sms_outbox
     set status = 'failed', error = 'No News and offers consent'
   where channel = 'marketing'
     and (status = 'queued' or (status = 'sending' and claimed_at < now() - interval '5 minutes'))
     and public.marketing_sms_consent(to_phone) <> 'opted_in';

  return query
  with claimed as (
    update public.sms_outbox o
       set status = 'sending', device_id = p_dev, claimed_at = now(), attempts = o.attempts + 1
     where o.id in (
       select q.id from public.sms_outbox q
        join public.messaging_routes r
          on r.channel = q.channel and r.direction = 'outbound'
         and r.transport = 'sms' and r.enabled and p_dev = any(r.device_ids)
        where (q.status = 'queued'
               or (q.status = 'sending' and q.device_id = p_dev and q.claimed_at < now() - interval '5 minutes'))
          and q.attempts < 3
        order by q.created_at
        limit greatest(1, least(coalesce(p_limit, 10), 50))
        for update of q skip locked
     )
    returning o.*
  )
  select (jsonb_populate_record(null::public.sms_outbox,
            to_jsonb(c) || jsonb_build_object('body', coalesce(s.body, c.body)))).*
    from claimed c
    left join public.sms_otp_secret s on s.outbox_id = c.id;
end;
$$;
revoke execute on function public.gateway_claim_for(uuid, integer) from public, anon, authenticated;

-- ---- 4. The admin's marketing send -------------------------------------------------------------
create or replace function public.admin_queue_marketing_sms(p_phones text[], p_body text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_body text := btrim(coalesce(p_body, ''));
  v_phone text;
  v_digits text;
  v_seen text[] := '{}';
  v_queued int := 0;
  v_not_opted int := 0;
  v_no_account int := 0;
  v_invalid int := 0;
  v_consent text;
begin
  if not public.caller_admin_can_write('sms_outbox') then
    raise exception 'NOT_ALLOWED' using errcode = '42501', hint = 'You can''t send marketing SMS.';
  end if;
  if char_length(v_body) not between 1 and 1600 then
    raise exception 'MARKETING_SMS_BODY' using errcode = '22023', hint = 'Write the message (up to 1600 characters).';
  end if;
  if coalesce(array_length(p_phones, 1), 0) > 10000 then
    raise exception 'MARKETING_SMS_TOO_MANY' using errcode = '22023', hint = 'Send to at most 10,000 numbers at a time.';
  end if;

  foreach v_phone in array coalesce(p_phones, '{}') loop
    v_digits := public.family_phone_digits(v_phone);
    if v_digits is null or v_digits !~ '^[0-9]{6,15}$' then
      v_invalid := v_invalid + 1;
      continue;
    end if;
    if v_digits = any(v_seen) then
      continue;
    end if;
    v_seen := v_seen || v_digits;
    v_consent := public.marketing_sms_consent(v_digits);
    if v_consent = 'opted_in' then
      insert into public.sms_outbox (channel, to_phone, body, created_by)
      values ('marketing', '+' || v_digits, v_body, auth.uid());
      v_queued := v_queued + 1;
    elsif v_consent = 'not_opted_in' then
      v_not_opted := v_not_opted + 1;
    else
      v_no_account := v_no_account + 1;
    end if;
  end loop;

  insert into public.admin_audit_log (actor_id, action, detail)
  values (auth.uid(), 'marketing_sms.queue',
          jsonb_build_object('queued', v_queued, 'notOptedIn', v_not_opted, 'noAccount', v_no_account,
                             'invalid', v_invalid));

  return jsonb_build_object(
    'queued', v_queued,
    'notOptedIn', v_not_opted,
    'noAccount', v_no_account,
    'invalid', v_invalid,
    'leftOut', v_not_opted + v_no_account + v_invalid);
end;
$$;
revoke execute on function public.admin_queue_marketing_sms(text[], text) from public, anon;
grant execute on function public.admin_queue_marketing_sms(text[], text) to authenticated;

create or replace function public.admin_marketing_sms_reach()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.caller_is_admin() then
    raise exception 'NOT_ALLOWED' using errcode = '42501';
  end if;
  return (
    select jsonb_build_object(
      'optedIn', count(*) filter (where p.news_offers),
      'withPhone', count(*))
      from public.profiles p
     where p.phone is not null and btrim(p.phone) <> ''
       and p.deleted_at is null and not p.store_review);
end;
$$;
revoke execute on function public.admin_marketing_sms_reach() from public, anon;
grant execute on function public.admin_marketing_sms_reach() to authenticated;

-- ---- 5. STOP -----------------------------------------------------------------------------------
create or replace function public.marketing_sms_is_stop(p_body text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select upper(btrim(regexp_replace(regexp_replace(coalesce(p_body, ''), '[^[:alpha:][:space:]]', '', 'g'),
                                    '[[:space:]]+', ' ', 'g')))
         in ('STOP', 'STOP ALL', 'UNSUBSCRIBE', 'BERHENTI');
$$;

create or replace function public.sms_inbox_marketing_stop()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_digits text := public.family_phone_digits(new.from_phone);
begin
  if v_digits is null or not public.marketing_sms_is_stop(new.body) then
    return new;
  end if;
  update public.profiles p
     set news_offers = false
   where p.news_offers
     and p.phone is not null
     and public.family_phone_digits(p.phone) = v_digits;
  update public.sms_outbox o
     set status = 'failed', error = 'Replied STOP'
   where o.channel = 'marketing' and o.status = 'queued'
     and public.family_phone_digits(o.to_phone) = v_digits;
  return new;
end;
$$;
revoke execute on function public.sms_inbox_marketing_stop() from public, anon, authenticated;

drop trigger if exists trg_sms_inbox_marketing_stop on public.sms_inbox;
create trigger trg_sms_inbox_marketing_stop
  after insert on public.sms_inbox
  for each row execute function public.sms_inbox_marketing_stop();

notify pgrst, 'reload schema';
