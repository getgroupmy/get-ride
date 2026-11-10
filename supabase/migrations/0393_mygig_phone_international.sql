-- myGiG phone numbers go international.
--
-- Until now the passenger's phone on a myGiG was normalised by
-- mygig_phone_digits, which forced a Malaysian country code onto anything that
-- wasn't already one: a leading 0 became 60, and any bare <=10-digit number was
-- prefixed with 60. That is correct for a Malaysia-only product but wrong the
-- moment the app lets the driver pick another country — a German or Singaporean
-- number would have 60 stuck in front of it and the fare would route nowhere.
--
-- The app now composes a full E.164 number (dial code + national number, trunk
-- 0 dropped) and sends it WITH its leading '+'. So the fix is simply: when the
-- input already carries a '+', trust it — take its digits as-is and never force
-- 60. The Malaysian branches stay for any legacy caller that still sends a bare,
-- un-prefixed local number (an older app build, a number typed without a code),
-- so nothing already stored changes meaning.
--
-- The function is applied symmetrically on both sides of every comparison
-- (mygig_lookup_inner normalises the stored registry number and the queried
-- number through it; mygig_block stores its result; the blocked-list match
-- compares normalised digits to normalised digits), and every number stored so
-- far is Malaysian, for which the new definition returns exactly what the old
-- one did. So this needs no backfill: existing numbers keep matching, and only
-- a newly entered non-Malaysian number is now normalised correctly instead of
-- being mis-prefixed.

create or replace function public.mygig_phone_digits(p_phone text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
           when d = '' then null
           -- Already a composed international number (the app sent a '+'): trust
           -- its digits, never force a country code onto it.
           when has_plus then d
           -- Legacy bare input (no '+'): keep the Malaysian normalisation so old
           -- callers and already-stored local numbers are unchanged.
           when d like '0%' then '60' || substr(d, 2)
           when char_length(d) <= 10 and d not like '60%' then '60' || d
           else d
         end
    from (
      select regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') d,
             btrim(coalesce(p_phone, '')) like '+%' has_plus
    ) x;
$$;
