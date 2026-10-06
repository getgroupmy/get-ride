-- ============================================================================
-- 0065: GET.coin transfer approval — recipient confirms before coins move
-- ----------------------------------------------------------------------------
-- Sending coins is now a two-step handshake instead of an instant transfer:
--   1. The sender confirms a recipient (wallet id, scanned QR or phone
--      number) and `wallet_request_coin_transfer` creates a *pending*
--      `wallet_transfer_requests` row (after a soft balance check). A push +
--      in-app popup tells the recipient who is sending and how much.
--   2. The recipient accepts or declines via `wallet_respond_coin_transfer`.
--      On accept the coins move atomically (same ledger rows as 0064 — the
--      0060 trigger applies both balances); the sender is told the recipient
--      approved. Requests expire after 15 minutes; the sender can cancel a
--      pending request with `wallet_cancel_transfer_request`.
--
-- State machine (status column):
--   pending -> accepted | declined | cancelled | expired | failed
-- `failed` = the sender no longer had enough coins at acceptance time.
-- State transitions are reported via the RPC return value (not exceptions)
-- so the status write itself is never rolled back.
--
-- The instant `wallet_transfer_coins` RPC (0064) stays in place for older
-- clients; new clients only fall back to it when this migration is missing.
-- ============================================================================

create table if not exists public.wallet_transfer_requests (
  id uuid primary key default gen_random_uuid(),
  from_user_id uuid not null,
  from_name text,
  to_user_id uuid not null,
  to_name text,
  -- GC being sent (locked in at request time).
  coins numeric(12,2) not null check (coins > 0),
  note text,
  status text not null default 'pending'
    check (status in ('pending','accepted','declined','cancelled','expired','failed')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  expires_at timestamptz not null default now() + interval '15 minutes'
);

create index if not exists wallet_transfer_requests_to_idx
  on public.wallet_transfer_requests(to_user_id, status, created_at desc);
create index if not exists wallet_transfer_requests_from_idx
  on public.wallet_transfer_requests(from_user_id, created_at desc);

alter table public.wallet_transfer_requests enable row level security;

-- Both parties watch rows over realtime; all writes go through the
-- security-definer RPCs below, so no insert/update policies are exposed.
drop policy if exists "wallet_transfer_requests read" on public.wallet_transfer_requests;
create policy "wallet_transfer_requests read"
  on public.wallet_transfer_requests for select using (true);

grant select on public.wallet_transfer_requests to anon, authenticated;

-- Realtime: both sides subscribe (recipient for incoming pending requests,
-- sender for the status change on their own request).
alter table public.wallet_transfer_requests replica identity full;

do $$
begin
  alter publication supabase_realtime add table public.wallet_transfer_requests;
exception
  when duplicate_object then null;
end$$;

-- ----------------------------------------------------------------------------
-- Step 1 — sender creates a pending transfer request.
-- Recipient resolution (id or phone) matches wallet_transfer_coins (0064).
-- ----------------------------------------------------------------------------
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
  if p_from is null then
    raise exception 'invalid_user';
  end if;
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
-- Step 2 — recipient accepts or declines.
-- Returns the resulting status ('accepted' | 'declined' | 'expired' |
-- 'failed') rather than raising, so the status write always commits.
-- ----------------------------------------------------------------------------
create or replace function public.wallet_respond_coin_transfer(
  p_request uuid,
  p_user uuid,
  p_accept boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r         public.wallet_transfer_requests;
  v_balance numeric;
  v_suffix  text;
begin
  if p_request is null or p_user is null then
    raise exception 'invalid_user';
  end if;

  select * into r
  from public.wallet_transfer_requests
  where id = p_request
  for update;

  if not found then
    raise exception 'request_not_found';
  end if;
  if r.to_user_id <> p_user then
    raise exception 'not_recipient';
  end if;
  if r.status <> 'pending' then
    raise exception 'request_not_pending';
  end if;

  if now() > r.expires_at then
    update public.wallet_transfer_requests
       set status = 'expired', responded_at = now()
     where id = r.id;
    return jsonb_build_object('status', 'expired', 'coins', r.coins,
                              'from_name', r.from_name, 'to_name', r.to_name);
  end if;

  if not p_accept then
    update public.wallet_transfer_requests
       set status = 'declined', responded_at = now()
     where id = r.id;
    return jsonb_build_object('status', 'declined', 'coins', r.coins,
                              'from_name', r.from_name, 'to_name', r.to_name);
  end if;

  -- Lock the sender's coin wallet so concurrent transfers serialise.
  insert into public.wallets (user_id, wallet_type, balance)
  values (r.from_user_id, 'get_coin', 0)
  on conflict (user_id, wallet_type) do nothing;

  select balance into v_balance
  from public.wallets
  where user_id = r.from_user_id and wallet_type = 'get_coin'
  for update;

  if v_balance is null or v_balance < r.coins then
    update public.wallet_transfer_requests
       set status = 'failed', responded_at = now()
     where id = r.id;
    return jsonb_build_object('status', 'failed', 'coins', r.coins,
                              'from_name', r.from_name, 'to_name', r.to_name);
  end if;

  v_suffix := coalesce(' — ' || r.note, '');

  -- Ledger-driven: the trg_wallet_tx_apply trigger moves both balances.
  insert into public.wallet_transactions (user_id, wallet_type, kind, amount, method, note)
  values
    (r.from_user_id, 'get_coin', 'transfer_out', -r.coins, 'p2p_transfer',
     'Sent to ' || coalesce(r.to_name, 'user') || v_suffix),
    (r.to_user_id, 'get_coin', 'transfer_in', r.coins, 'p2p_transfer',
     'Received from ' || coalesce(r.from_name, 'user') || v_suffix);

  update public.wallet_transfer_requests
     set status = 'accepted', responded_at = now()
   where id = r.id;

  return jsonb_build_object('status', 'accepted', 'coins', r.coins,
                            'from_name', r.from_name, 'to_name', r.to_name);
end;
$$;

grant execute on function public.wallet_respond_coin_transfer(uuid, uuid, boolean)
  to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Sender cancels their own pending request.
-- ----------------------------------------------------------------------------
create or replace function public.wallet_cancel_transfer_request(
  p_request uuid,
  p_user uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.wallet_transfer_requests
     set status = 'cancelled', responded_at = now()
   where id = p_request and from_user_id = p_user and status = 'pending';
  return found;
end;
$$;

grant execute on function public.wallet_cancel_transfer_request(uuid, uuid)
  to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Push notifications via the send-push edge function (pg_net + Vault, same
-- setup as 0051 — no-ops quietly when the secrets aren't configured):
--   * INSERT           -> tell the recipient who is sending and how much
--   * pending -> final -> tell the sender the outcome (accepted/declined/…)
-- ----------------------------------------------------------------------------
create extension if not exists pg_net with schema extensions;

create or replace function public.notify_wallet_transfer_request()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_url  text;
  v_key  text;
begin
  if new.status is distinct from 'pending' then
    return new;
  end if;

  begin
    select decrypted_secret into v_url
      from vault.decrypted_secrets where name = 'project_url' limit 1;
    select decrypted_secret into v_key
      from vault.decrypted_secrets where name = 'service_role_key' limit 1;
  exception when others then
    return new;
  end;

  if v_url is null or v_key is null then
    return new;
  end if;

  perform net.http_post(
    url     := v_url || '/functions/v1/send-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body    := jsonb_build_object(
      'title', 'GET.coin transfer request',
      'body', coalesce(nullif(new.from_name, ''), 'Someone')
              || ' wants to send you ' || new.coins::text || ' GC',
      'profileId', new.to_user_id,
      'data', jsonb_build_object(
        'type', 'wallet_transfer_request',
        'request_id', new.id
      )
    )
  );

  return new;
exception when others then
  -- Never let a notification failure block the request.
  return new;
end;
$$;

create or replace function public.notify_wallet_transfer_response()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_url  text;
  v_key  text;
  v_body text;
begin
  if old.status is distinct from 'pending'
     or new.status not in ('accepted', 'declined', 'failed') then
    return new;
  end if;

  begin
    select decrypted_secret into v_url
      from vault.decrypted_secrets where name = 'project_url' limit 1;
    select decrypted_secret into v_key
      from vault.decrypted_secrets where name = 'service_role_key' limit 1;
  exception when others then
    return new;
  end;

  if v_url is null or v_key is null then
    return new;
  end if;

  v_body := case new.status
    when 'accepted' then coalesce(nullif(new.to_name, ''), 'The recipient')
                         || ' approved your request — ' || new.coins::text || ' GC sent'
    when 'declined' then coalesce(nullif(new.to_name, ''), 'The recipient')
                         || ' declined your transfer of ' || new.coins::text || ' GC'
    else 'Your transfer of ' || new.coins::text || ' GC failed — not enough GET.coin'
  end;

  perform net.http_post(
    url     := v_url || '/functions/v1/send-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body    := jsonb_build_object(
      'title', 'GET.coin transfer',
      'body', v_body,
      'profileId', new.from_user_id,
      'data', jsonb_build_object(
        'type', 'wallet_transfer_response',
        'request_id', new.id,
        'status', new.status
      )
    )
  );

  return new;
exception when others then
  return new;
end;
$$;

do $$
begin
  drop trigger if exists trg_wallet_transfer_request_push on public.wallet_transfer_requests;
  create trigger trg_wallet_transfer_request_push
    after insert on public.wallet_transfer_requests
    for each row execute function public.notify_wallet_transfer_request();

  drop trigger if exists trg_wallet_transfer_response_push on public.wallet_transfer_requests;
  create trigger trg_wallet_transfer_response_push
    after update on public.wallet_transfer_requests
    for each row execute function public.notify_wallet_transfer_response();
end$$;
