-- 0444: get.ocr is the primary document reader -------------------------------
--
-- Makes get.ocr (DocReaderId.getOcr, migration 0443) the first reader in the
-- document reading chain, switched on, so every document read tries the org's
-- own OCR server first and falls back to the readers after it (the office NAS,
-- a GPU PC, the cloud / Google Vision reader) in the order the admin sets. The
-- admin can re-arrange it or switch it off in Admin -> Settings -> Document
-- reading. Mirrors lib/src/core/document_reading.dart (getOcr leads, on).
--
-- Two changes to document_reading_normalize (0293 / 0443):
--   * get.ocr leads the known order, so a fresh config reads
--     getOcr, phone, nas, gpu, cloud;
--   * a reader missing from a saved list joins on -- get.ocr included (it was
--     opt-in off in 0443).
-- Plus a one-time move of the stored config so the live chain leads with
-- get.ocr; the admin's own order and switches for the other readers are kept.

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
    'passOnBelow', greatest(50, least(100, round(coalesce(v_pass, 90)))));
end;
$$;
revoke execute on function public.document_reading_normalize(jsonb) from public, anon, authenticated;

-- One-time: lead the stored chain with get.ocr (on), keeping the admin's order
-- for the rest. Harmless if no config has been saved yet (the defaults already
-- lead with get.ocr) -- the update then touches no row.
update public.app_settings
set value = jsonb_set(
  public.document_reading_normalize(value),
  '{readers}',
  jsonb_build_array(jsonb_build_object('id', 'getOcr', 'on', true))
    || coalesce((
         select jsonb_agg(r order by ord)
         from jsonb_array_elements(public.document_reading_normalize(value) -> 'readers')
              with ordinality as t(r, ord)
         where r ->> 'id' <> 'getOcr'
       ), '[]'::jsonb))
where key = 'document_reading';
