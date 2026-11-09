-- ============================================================================
-- 0388: Vehicle ownership certificate (VOC) as a compulsory vehicle document.
--
-- Every vehicle must have its ownership certificate on file — in Malaysia the
-- JPJ "geran"; the document is named differently in each country. It is a
-- normal vehicle document, so the existing upload / review / verify flow
-- (approver + admin) already covers viewing and verifying it; this migration
-- just registers the type so it appears, required, in that flow. The
-- `readAs: 'voc'` marker lets the app find "the ownership certificate"
-- regardless of its per-country name (used by the scan-to-autofill flow and,
-- later, the completion gate), the same way "puspakom" marks the inspection.
--
-- Idempotent: inserted only when no VOC type exists yet. Admins can rename it
-- per country, or add country-specific rows, from Admin -> Settings ->
-- Required Documents.
-- ============================================================================

insert into public.required_document (values, position, active)
select jsonb_build_object(
         'name', 'Vehicle Ownership Certificate',
         'readAs', 'voc',
         'isPwd', false,
         'active', true,
         'regions', '[]',
         'docTypes', '["a7d71867-ac2a-4c0c-ae07-87e5d500693c"]',
         'hasPhoto', false,
         'required', true,
         'description', 'The vehicle''s ownership certificate (Malaysia: JPJ geran). Named differently in each country.',
         'isTaxiPermit', false,
         'partnerTypes', '[]',
         'regionsGlobal', true,
         'allowPdfUpload', true,
         'requireFrontBack', false,
         'requireStartDate', false,
         'requireExpiryDate', false,
         'requireDocumentNumber', true,
         'regionsGlobalCompulsory', true,
         'requireInsuranceProvider', false),
       coalesce((select max(position) + 1 from public.required_document), 0),
       true
 where not exists (
   select 1 from public.required_document rd where rd.values->>'readAs' = 'voc'
 );

notify pgrst, 'reload schema';
