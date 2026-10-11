-- ============================================================================
-- 0146: a chat message is "delivered" when it reaches the other phone, and a
-- resent message is never stored twice
--
-- ride_messages already ticks 'sent' → 'delivered' → 'read' (0129), but only
-- the open chat moved a message to delivered: a message that reached the
-- other phone as a push, with the chat closed, stayed on one tick. And a send
-- retried after a dropped connection could store the same message twice.
--
--   * client_msg_id: the id the sending phone gives a message. It is unique,
--     so a send retried with the same id is stored once (the app inserts with
--     ON CONFLICT DO NOTHING);
--   * the chat push goes through the notification outbox (0144) with the
--     event id 'msg:<message id>': it is retried once after 2 minutes until
--     the receiving phone acknowledges it, and not at all once the message
--     is delivered;
--   * ack_notification on a chat push marks the message delivered (read when
--     the push was tapped), so the sender sees two ticks as soon as the push
--     lands;
--   * a message marked delivered or read in the chat closes its push in the
--     outbox, so it is not sent again.
-- ============================================================================

alter table public.ride_messages add column if not exists client_msg_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.ride_messages'::regclass and conname = 'ride_messages_client_msg_id_key'
  ) then
    alter table public.ride_messages add constraint ride_messages_client_msg_id_key unique (client_msg_id);
  end if;
end $$;

-- ---- The chat push, through the outbox -----------------------------------------
create or replace function public.notify_ride_message_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_to uuid;
  v_to_role text;
  v_title text;
begin
  select rider_id, partner_id, rider_name, partner_name into r
    from public.ride_requests where id = new.request_id;
  if new.sender_role = 'rider' then
    v_to := r.partner_id;
    v_to_role := 'partner';
    v_title := coalesce(nullif(btrim(coalesce(r.rider_name, '')), ''), 'Your passenger');
  else
    v_to := r.rider_id;
    v_to_role := 'rider';
    v_title := coalesce(nullif(btrim(coalesce(r.partner_name, '')), ''), 'Your driver');
  end if;
  if v_to is null or v_to = new.sender_id then
    return new;
  end if;
  perform public.enqueue_notification(
    v_to,
    'msg:' || new.id,
    'ride_message',
    'normal',
    v_title,
    public.ride_message_push_body(new.type, new.body),
    jsonb_build_object('type', 'ride_message', 'request_id', new.request_id, 'role', v_to_role,
                       'message_id', new.id),
    new.request_id
  );
  return new;
exception when others then
  return new;
end;
$$;

revoke execute on function public.notify_ride_message_push() from public, anon, authenticated;

-- ---- A message the chat already delivered needs no more pushes -------------------
create or replace function public.notification_still_relevant(r public.notification_outbox)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v public.ride_requests;
begin
  if r.kind = 'ride_message' then
    return exists (
      select 1 from public.ride_messages m
       where m.id::text = r.data->>'message_id' and m.status = 'sent'
    );
  end if;
  if r.request_id is null then
    return true;
  end if;
  select * into v from public.ride_requests where id = r.request_id;
  if not found then
    return false;
  end if;
  if r.data ? 'status' and v.status is distinct from r.data->>'status' then
    return false;
  end if;
  if r.data ? 'payment_status' and v.payment_status is distinct from r.data->>'payment_status' then
    return false;
  end if;
  if r.data->>'type' = 'ride_cancel_request' and v.cancel_requested_at is null then
    return false;
  end if;
  return true;
end;
$$;

revoke execute on function public.notification_still_relevant(public.notification_outbox) from public, anon, authenticated;

-- ---- The push landed: the message is delivered (or read, if it was tapped) --------
create or replace function public.ack_notification(p_event_id text, p_state text default 'delivered')
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
  v_message uuid;
begin
  if auth.uid() is null then
    return 0;
  end if;
  update public.notification_outbox
     set delivered_at = coalesce(delivered_at, now()),
         read_at = case when p_state = 'read' then coalesce(read_at, now()) else read_at end,
         next_attempt_at = null
   where profile_id = auth.uid() and event_id = p_event_id
  returning case when kind = 'ride_message' then (data->>'message_id')::uuid end into v_message;
  get diagnostics n = row_count;

  -- Only the receiver has the outbox row, and only the receiver may move the
  -- tick (ride_messages_guard_update checks auth.uid() all the same).
  if v_message is not null then
    begin
      update public.ride_messages
         set status = case when p_state = 'read' then 'read' else 'delivered' end
       where id = v_message
         and status in ('sent', case when p_state = 'read' then 'delivered' else 'sent' end);
    exception when others then
      null;
    end;
  end if;
  return n;
end;
$$;

revoke execute on function public.ack_notification(text, text) from public, anon;
grant execute on function public.ack_notification(text, text) to authenticated;

-- ---- The chat delivered it: close its push ---------------------------------------------
create or replace function public.ride_message_close_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.notification_outbox
     set delivered_at = coalesce(delivered_at, now()),
         read_at = case when new.status = 'read' then coalesce(read_at, now()) else read_at end,
         next_attempt_at = null
   where event_id = 'msg:' || new.id
     and (delivered_at is null or (new.status = 'read' and read_at is null));
  return new;
exception when others then
  return new;
end;
$$;

revoke execute on function public.ride_message_close_push() from public, anon, authenticated;

drop trigger if exists trg_ride_messages_close_push on public.ride_messages;
create trigger trg_ride_messages_close_push after update of status on public.ride_messages
  for each row when (new.status is distinct from old.status)
  execute function public.ride_message_close_push();

notify pgrst, 'reload schema';
