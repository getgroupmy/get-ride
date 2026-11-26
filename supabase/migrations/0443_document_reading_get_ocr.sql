-- 0443: GET OCR as a document reader ----------------------------------------
--
-- get.ocr (ocr.getcdn.link) joins the document reading chain (0293) as a fifth
-- reader, 'getOcr' (lib/src/core/document_reading.dart, DocReaderId.getOcr):
-- the org's own OCR server reads the whole document, selectable and orderable
-- in Admin -> Settings -> Document reading alongside the phone, the office NAS,
-- a GPU reading PC and the cloud reader. Its key is Admin -> API Keys -> GET
-- OCR; the id-read function calls it (reader: "getOcr") when it is next.
--
-- Only document_reading_normalize changes: 'getOcr' becomes an accepted reader
-- id. A reader missing from a saved list still joins at the end, on, EXCEPT
-- get.ocr, which joins OFF (opt-in) -- so no existing install starts routing
-- documents to get.ocr until an admin turns the reader on. The rest of the
-- function is unchanged from 0293.

create or replace function public.document_reading_normalize(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public
as $$
declare
  v_known constant text[] := array['phone', 'nas', 'gpu', 'cloud', 'getOcr'];
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
  -- A reader missing from the saved list joins at the end. The known readers
  -- join on, except get.ocr, which is opt-in (off until an admin turns it on).
  foreach v_id in array v_known loop
    if not v_id = any(v_seen) then
      v_readers := v_readers || jsonb_build_object('id', v_id, 'on', v_id <> 'getOcr');
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
    'passOnBelow', greatest(50, least(100, round(coalesce(v_pass, 90)))));
end;
$$;
revoke execute on function public.document_reading_normalize(jsonb) from public, anon, authenticated;
