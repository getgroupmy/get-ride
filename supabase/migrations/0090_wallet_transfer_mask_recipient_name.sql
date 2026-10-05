-- ============================================================================
-- 0090 — mask the recipient's name in P2P GET.coin transfers
-- ----------------------------------------------------------------------------
-- `wallet_request_coin_transfer` (0065) and the instant `wallet_transfer_coins`
-- (0064) resolve the recipient by account id or phone number and returned
-- their full account name as `recipient_name`. `wallet_request_coin_transfer`
-- also stored it in `wallet_transfer_requests.to_name`, which the sender can
-- read back (0089 keeps the row readable by its sender). Anyone signed in and
-- holding 0.01 GC could therefore map phone numbers to full names by creating
-- requests and cancelling them.
--
-- Fix: `wallet_mask_name()` reduces a name to first word + last initial
-- ("Ahmad bin Ali" -> "Ahmad A."; a single word -> "K***"), and both
-- functions mask the recipient's name before it is returned, stored on the
-- request row, written into the sender's ledger memo or used in the
-- accepted/declined push to the sender. The sender's name, shown to the
-- recipient in the approval popup, is unchanged.
--
-- Existing data is masked too (end of file): `to_name` on every request row,
-- and the name in the sender's "Sent to <name>[ — <note>]" ledger memo on
-- p2p_transfer_out rows. wallet_mask_name() is idempotent, so re-running is
-- safe.
--
-- Function bodies are otherwise identical to 0066.
-- ============================================================================

-- Masks an account name for display to someone who is not its owner:
-- first word + initial of the last word ("Ahmad bin Ali" -> "Ahmad A."),
-- a single word keeps only its first letter ("Kumar" -> "K***"). Null/blank
-- in, null out.
create or replace function public.wallet_mask_name(p_name text)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when w is null or cardinality(w) = 0 then null
    when cardinality(w) = 1 then left(w[1], 1) || '***'
    else w[1] || ' ' || upper(left(w[cardinality(w)], 1)) || '.'
  end
  from (
    select nullif(regexp_split_to_array(btrim(coalesce(p_name, '')), '\s+'), array['']) as w
  ) t;
$$;

create or replace function public.wallet_transfer_coins(
  p_from uuid,
  p_coins numeric,
  p_to uuid default null,
  p_to_phone text default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coins     numeric := round(coalesce(p_coins, 0), 2);
  v_to        uuid    := p_to;
  v_to_name   text;
  v_from_name text;
  v_digits    text;
  v_balance   numeric;
  v_after     numeric;
  v_suffix    text := coalesce(' — ' || nullif(trim(p_note), ''), '');
begin
  perform public.wallet_assert_caller(p_from);
  if v_coins <= 0 or v_coins > 1000000 then
    raise exception 'invalid_amount';
  end if;

  if v_to is not null then
    select coalesce(name, '') into v_to_name from public.profiles where id = v_to;
    if not found then
      select coalesce(name, '') into v_to_name from public.partners where id = v_to;
      if not found then
        raise exception 'recipient_not_found';
      end if;
    end if;
  else
    -- Resolve by phone: compare digits only, so "+60 12-345 6789" and
    -- "0123456789" line up; fall back to matching the last 9 digits to
    -- bridge country-code prefixes.
    v_digits := regexp_replace(coalesce(p_to_phone, ''), '\D', '', 'g');
    if length(v_digits) < 7 then
      raise exception 'recipient_not_found';
    end if;

    select id, coalesce(name, '') into v_to, v_to_name
    from public.profiles
    where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = v_digits
       or (length(v_digits) >= 9
           and right(regexp_replace(coalesce(phone, ''), '\D', '', 'g'), 9) = right(v_digits, 9))
    order by created_at
    limit 1;

    if v_to is null then
      select id, coalesce(name, '') into v_to, v_to_name
      from public.partners
      where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = v_digits
         or (length(v_digits) >= 9
             and right(regexp_replace(coalesce(phone, ''), '\D', '', 'g'), 9) = right(v_digits, 9))
      order by created_at
      limit 1;
    end if;

    if v_to is null then
      raise exception 'recipient_not_found';
    end if;
  end if;

  if v_to = p_from then
    raise exception 'self_transfer';
  end if;

  -- 0090: the sender only ever sees a masked name ("Ahmad A."), so a phone
  -- number cannot be mapped to a full account name before acceptance.
  v_to_name := coalesce(public.wallet_mask_name(v_to_name), '');

  select coalesce(name, '') into v_from_name from public.profiles where id = p_from;
  if not found then
    select coalesce(name, '') into v_from_name from public.partners where id = p_from;
  end if;

  -- Lock the sender's coin wallet so concurrent transfers serialise.
  insert into public.wallets (user_id, wallet_type, balance)
  values (p_from, 'get_coin', 0)
  on conflict (user_id, wallet_type) do nothing;

  select balance into v_balance
  from public.wallets
  where user_id = p_from and wallet_type = 'get_coin'
  for update;

  if v_balance is null or v_balance < v_coins then
    raise exception 'insufficient_coins';
  end if;

  -- Ledger-driven: the trg_wallet_tx_apply trigger moves both balances.
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
  values
    (p_from, 'get_coin', 'transfer_out', -v_coins, 'p2p_transfer',
     'Sent to ' || coalesce(nullif(v_to_name, ''), 'user') || v_suffix),
    (v_to, 'get_coin', 'transfer_in', v_coins, 'p2p_transfer',
     'Received from ' || coalesce(nullif(v_from_name, ''), 'user') || v_suffix);

  select balance into v_after
  from public.wallets
  where user_id = p_from and wallet_type = 'get_coin';

  return jsonb_build_object(
    'coins',          v_coins,
    'recipient_id',   v_to,
    'recipient_name', nullif(v_to_name, ''),
    'balance_after',  v_after
  );
end;
$$;

grant execute on function public.wallet_transfer_coins(uuid, numeric, uuid, text, text)
  to anon, authenticated;

create or replace function public.wallet_request_coin_transfer(
  p_from uuid,
  p_coins numeric,
  p_to uuid default null,
  p_to_phone text default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coins     numeric := round(coalesce(p_coins, 0), 2);
  v_to        uuid    := p_to;
  v_to_name   text;
  v_from_name text;
  v_digits    text;
  v_balance   numeric;
  v_request   public.wallet_transfer_requests;
begin
  perform public.wallet_assert_caller(p_from);
  if v_coins <= 0 or v_coins > 1000000 then
    raise exception 'invalid_amount';
  end if;

  if v_to is not null then
    select coalesce(name, '') into v_to_name from public.profiles where id = v_to;
    if not found then
      select coalesce(name, '') into v_to_name from public.partners where id = v_to;
      if not found then
        raise exception 'recipient_not_found';
      end if;
    end if;
  else
    v_digits := regexp_replace(coalesce(p_to_phone, ''), '\D', '', 'g');
    if length(v_digits) < 7 then
      raise exception 'recipient_not_found';
    end if;

    select id, coalesce(name, '') into v_to, v_to_name
    from public.profiles
    where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = v_digits
       or (length(v_digits) >= 9
           and right(regexp_replace(coalesce(phone, ''), '\D', '', 'g'), 9) = right(v_digits, 9))
    order by created_at
    limit 1;

    if v_to is null then
      select id, coalesce(name, '') into v_to, v_to_name
      from public.partners
      where regexp_replace(coalesce(phone, ''), '\D', '', 'g') = v_digits
         or (length(v_digits) >= 9
             and right(regexp_replace(coalesce(phone, ''), '\D', '', 'g'), 9) = right(v_digits, 9))
      order by created_at
      limit 1;
    end if;

    if v_to is null then
      raise exception 'recipient_not_found';
    end if;
  end if;

  if v_to = p_from then
    raise exception 'self_transfer';
  end if;

  -- 0090: the sender only ever sees a masked name ("Ahmad A."), so a phone
  -- number cannot be mapped to a full account name before acceptance.
  v_to_name := coalesce(public.wallet_mask_name(v_to_name), '');

  select coalesce(name, '') into v_from_name from public.profiles where id = p_from;
  if not found then
    select coalesce(name, '') into v_from_name from public.partners where id = p_from;
  end if;

  -- Soft balance check so obviously unfunded requests never reach the
  -- recipient. The authoritative check re-runs at acceptance time.
  select balance into v_balance
  from public.wallets
  where user_id = p_from and wallet_type = 'get_coin';

  if v_balance is null or v_balance < v_coins then
    raise exception 'insufficient_coins';
  end if;

  insert into public.wallet_transfer_requests
    (from_user_id, from_name, to_user_id, to_name, coins, note)
  values
    (p_from, nullif(v_from_name, ''), v_to, nullif(v_to_name, ''), v_coins,
     nullif(trim(coalesce(p_note, '')), ''))
  returning * into v_request;

  return jsonb_build_object(
    'request_id',     v_request.id,
    'recipient_id',   v_to,
    'recipient_name', nullif(v_to_name, ''),
    'coins',          v_coins,
    'expires_at',     v_request.expires_at
  );
end;
$$;

grant execute on function public.wallet_request_coin_transfer(uuid, numeric, uuid, text, text)
  to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Backfill: mask names already stored.
-- ----------------------------------------------------------------------------

-- Request rows. Only status-changing updates send a push, so this is silent;
-- participants subscribed over realtime get an UPDATE their popups ignore.
update public.wallet_transfer_requests
   set to_name = public.wallet_mask_name(to_name)
 where to_name is not null
   and to_name is distinct from public.wallet_mask_name(to_name);

-- Sender ledger memos. trg_wallet_tx_apply re-applies the amount and rewrites
-- balance_after to the *current* balance on any UPDATE, which would corrupt
-- the history of a memo-only change, so it is disabled for this one
-- statement. Inside a DO block the disable, update and re-enable are a single
-- statement: if anything fails, all of it rolls back and the trigger is never
-- left off. The ACCESS EXCLUSIVE lock from ALTER TABLE holds new ledger
-- inserts until the block commits, so none can slip past the trigger.
-- Skipped: the "user" placeholder (no name was known) and the pre-0064
-- client fallback "Sent to 1a2b3c4d…" (an id prefix, not a name).
do $$
begin
  alter table public.wallet_transactions disable trigger trg_wallet_tx_apply;

  update public.wallet_transactions t
     set note = 'Sent to ' || public.wallet_mask_name(m.name) || m.rest
    from (
      select id,
             split_part(substr(note, 9), ' — ', 1) as name,
             substr(substr(note, 9), length(split_part(substr(note, 9), ' — ', 1)) + 1) as rest
        from public.wallet_transactions
       where kind = 'transfer_out'
         and method = 'p2p_transfer'
         and note like 'Sent to %'
    ) m
   where t.id = m.id
     and btrim(m.name) <> ''
     and m.name <> 'user'
     and m.name !~ '^[0-9a-f]{8}…$'
     and m.name is distinct from public.wallet_mask_name(m.name);

  alter table public.wallet_transactions enable trigger trg_wallet_tx_apply;
end$$;

notify pgrst, 'reload schema';
