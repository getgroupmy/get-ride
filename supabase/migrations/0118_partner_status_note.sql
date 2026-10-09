-- 0118: Why a partner was rejected or blocked, and sending a rejected
-- application back for review.
--
-- An admin who rejects or blocks a partner can say why (`status_note`); the
-- partner sees it on the Drive tab. A rejected partner who has fixed what
-- was asked sends the application back with partner_request_review(), which
-- moves it to unapproved (the admin queue) and stamps `resubmitted_at`. Only
-- an admin approves; a blocked partner can only contact support.
--
-- Both columns are the admin's / the server's: the partner cannot write them
-- directly (partners_guard_protected_columns).

alter table public.partners
  add column if not exists status_note text check (status_note is null or length(status_note) <= 500),
  add column if not exists resubmitted_at timestamptz;

create or replace function public.partners_guard_protected_columns()
  returns trigger
  language plpgsql
  set search_path to 'public'
as $function$
declare
  v_old jsonb;
  v_new jsonb;
  v_col text;
begin
  if current_user not in ('anon', 'authenticated') or public.caller_is_admin() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status is distinct from 'unapproved' then
      raise exception 'PARTNERS_PROTECTED_COLUMN:status' using errcode = '42501',
        hint = 'A new partner starts unapproved; an administrator approves it.';
    end if;
    if new.permit is not null and new.permit::text not in ('none', 'pending') then
      raise exception 'PARTNERS_PROTECTED_COLUMN:permit' using errcode = '42501';
    end if;
    if coalesce(new.rating, 0) <> 0 then
      raise exception 'PARTNERS_PROTECTED_COLUMN:rating' using errcode = '42501';
    end if;
    if coalesce(new.total_rides, 0) <> 0 then
      raise exception 'PARTNERS_PROTECTED_COLUMN:total_rides' using errcode = '42501';
    end if;
    if new.status_note is not null or new.resubmitted_at is not null then
      raise exception 'PARTNERS_PROTECTED_COLUMN:status_note' using errcode = '42501';
    end if;
    return new;
  end if;

  v_old := to_jsonb(old);
  v_new := to_jsonb(new);
  foreach v_col in array array[
    'id', 'auth_user_id', 'display_id', 'status', 'permit', 'rating',
    'total_rides', 'joined_at', 'created_at', 'status_note', 'resubmitted_at'
  ] loop
    if v_old -> v_col is distinct from v_new -> v_col then
      raise exception 'PARTNERS_PROTECTED_COLUMN:%', v_col using errcode = '42501',
        hint = 'This field can only be changed by an administrator or by the server.';
    end if;
  end loop;
  return new;
end;
$function$;

-- The signed-in partner's rejected application, back to the admin queue.
create or replace function public.partner_request_review()
  returns public.partners
  language plpgsql
  security definer
  set search_path to 'public'
as $function$
declare
  v_partner public.partners;
begin
  if auth.uid() is null then
    raise exception 'NOT_SIGNED_IN' using errcode = '42501';
  end if;
  select * into v_partner from public.partners where auth_user_id = auth.uid() order by created_at limit 1 for update;
  if not found then
    raise exception 'PARTNER_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_partner.status <> 'rejected' then
    raise exception 'PARTNER_NOT_REJECTED' using errcode = '22023',
      hint = 'Only a rejected application can be sent back for review.';
  end if;
  update public.partners
     set status = 'unapproved', resubmitted_at = now(), updated_at = now()
   where id = v_partner.id
   returning * into v_partner;
  return v_partner;
end;
$function$;

revoke all on function public.partner_request_review() from public, anon;
grant execute on function public.partner_request_review() to authenticated;
