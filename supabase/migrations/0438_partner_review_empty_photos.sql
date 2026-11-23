-- ============================================================================
-- 0438 — An empty photos line is decided without a view.
--
-- 0296 holds a line with a document (its photo or file) back from Approve or
-- Reject until the admin has opened it — "Open the document first". It decided
-- a line "has a document" from its value being non-null and not JSON null.
-- That is right for a single photo or file (an unset one is to_jsonb(null) =
-- 'null'::jsonb, correctly nothing to view), but wrong for the lines whose
-- value is an array of URLs: vehicle photos (image_front/left/right/back), the
-- vehicle grant (front/back) and the driver permit photos (front/back). With
-- none uploaded their value is jsonb_build_array(null, null, null, null) — a
-- non-null array, so the gate fired, yet there was nothing to open. The admin
-- could never log a view and was locked out of both Approve and Reject
-- (reported: "there is no image uploaded but the admin cannot reject").
--
-- The app already treats these lines as nothing to view: its "View" button and
-- reviewNeedsView() keep only the non-null URLs (lib/src/core/partner_review.dart),
-- so an empty photos line has an empty file list and decides freely. This
-- brings the server's gate in line with that.
--
-- partner_review_has_file(value): whether the line's stored value actually
-- holds a file to look at. A scalar or object value keeps its old meaning (any
-- non-null, non-JSON-null value counts); an array counts only when it holds at
-- least one real (non-null, non-empty string) entry, so an all-null or empty
-- photos array is nothing to view. partner_review_items_viewed is recreated
-- from its 0296 body with only the gate condition changed to use it — same
-- signature, same trigger, no DROP. The app is not touched.
--
-- supabase/tests/partner_review_empty_photos_0438.sql covers it.
-- ============================================================================

-- Whether the line's stored value holds a file to look at (its photo or file).
create or replace function public.partner_review_has_file(v jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select v is not null
     and v <> 'null'::jsonb
     and (jsonb_typeof(v) <> 'array'
          or exists (
            select 1 from jsonb_array_elements(v) e
             where jsonb_typeof(e) = 'string' and length(btrim(e #>> '{}')) > 0
          ));
$$;

-- A line with a document to look at is decided only once this admin has viewed
-- it since it last went back to pending (0296); an all-null or empty photos
-- array is nothing to view, so it decides without one (0438).
create or replace function public.partner_review_items_viewed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  me uuid := auth.uid();
  since timestamptz;
begin
  -- The service role and the driver's own changes (fixed_at, kept_at,
  -- sent_at) are not decisions.
  if me is null or not public.caller_is_admin() then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.state is not distinct from old.state
     and new.decided_at is not distinct from old.decided_at then
    return new;
  end if;
  if public.partner_review_has_document(new.item_key)
     and public.partner_review_has_file(public.partner_review_value(new.partner_id, new.item_key)) then
    select max(at) into since from public.partner_review_log
     where partner_id = new.partner_id and item_key = new.item_key and action = 'pending';
    if not exists (
      select 1 from public.partner_review_log
       where partner_id = new.partner_id and item_key = new.item_key and action = 'viewed'
         and actor_id = me and at > coalesce(since, '-infinity'::timestamptz)
    ) then
      raise exception 'REVIEW_VIEW_FIRST' using errcode = '22023',
        hint = 'Open the document first: it is decided only once you have viewed it.';
    end if;
  end if;
  return new;
end;
$$;
