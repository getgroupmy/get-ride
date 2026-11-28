-- 0447: GET.ocr MyKad reader switch -------------------------------------------
--
-- Adds a `mykadReader` boolean to the document_reading config so the admin can
-- switch GET.ocr's own MyKad reader (its /v1/extract type "mykad", read by
-- position) on or off in Admin -> Document reading. Off by default: today's
-- GET.ocr still answers type "mykad" with the old reader (two-line names cut,
-- new-generation cards misread), so a MyKad is read by the text readers until
-- the owner turns this on, once GET.ocr's new MyKad reader is live on the Mac
-- mini (the id-read function gates on this switch, not on the answer's read_by).
--
-- document_reading_normalize (0293 / 0444) rebuilds the whole config on every
-- save (admin_document_reading_set), so it must carry the new key or it is
-- dropped. Only the returned object gains one key; the reader-order logic is
-- unchanged. Reversible: restore the 0444 body (drop the mykadReader key).

create or replace function public.document_reading_normalize(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_known constant text[] := array['getOcr', 'phone', 'nas', 'gpu', 'cloud'];
  v_seen text[] := '{}';
  v_readers jsonb := '[]'::jsonb;
  v_r jsonb;
  v_id text;
  v_jobs jsonb := coalesce(p -> 'nasJobs', '{}'::jsonb);
  v_pass numeric;
begin
  if jsonb_typeof(p -> 'readers') = 'array' then
    for v_r in select * from jsonb_array_elements(p -> 'readers') loop
      v_id := v_r ->> 'id';
      if v_id = any(v_known) and not v_id = any(v_seen) then
        v_seen := v_seen || v_id;
        v_readers := v_readers || jsonb_build_object('id', v_id, 'on', coalesce((v_r ->> 'on')::boolean, true));
      end if;
    end loop;
  end if;
  -- A reader missing from the saved list joins on, in the known order
  -- (get.ocr leads, as the primary reader).
  foreach v_id in array v_known loop
    if not v_id = any(v_seen) then
      v_readers := v_readers || jsonb_build_object('id', v_id, 'on', true);
    end if;
  end loop;

  v_pass := case when (p ->> 'passOnBelow') ~ '^\d+(\.\d+)?$' then (p ->> 'passOnBelow')::numeric end;
  return jsonb_build_object(
    'readers', v_readers,
    'nasJobs', jsonb_build_object(
      'plates',  coalesce((v_jobs ->> 'plates')::boolean, true),
      'numbers', coalesce((v_jobs ->> 'numbers')::boolean, true),
      'qr',      coalesce((v_jobs ->> 'qr')::boolean, true),
      'checks',  coalesce((v_jobs ->> 'checks')::boolean, true)),
    'passOnBelow', greatest(50, least(100, round(coalesce(v_pass, 90)))),
    'mykadReader', coalesce((p ->> 'mykadReader')::boolean, false));
end;
$$;
revoke execute on function public.document_reading_normalize(jsonb) from public, anon, authenticated;
