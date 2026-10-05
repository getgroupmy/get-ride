-- ============================================================================
-- 0086 — Meter Digital: name the dispatch app, and where to install it
-- ----------------------------------------------------------------------------
-- 0085 let the meter's e-hailing key open another app, but only by a link the
-- operator had to know and type. An admin picking their fleet's dispatch app
-- should not have to know what a URL scheme is, so the card can now name an app
-- from the in-app catalogue (`expo/utils/meterLeaveApps.ts`) instead:
--
--   * `leave_ehailing_app_id` — the catalogue entry the operator picked. Stored
--     beside `leave_ehailing_url` rather than instead of it, because the two
--     answer different questions: the id lets each platform be given its own
--     way in (an Android package launches by intent, an iPhone needs that app's
--     own scheme), while the link stays the operator's override and the only
--     thing a card needs for an app the catalogue does not carry.
--   * `leave_ehailing_store_*` — where to send a driver whose phone does not
--     have the app. One per platform because none is derivable from another: a
--     package id *is* the Play address, but App Store and AppGallery pages are
--     numeric ids that no package name yields. Huawei is listed separately from
--     Android for exactly that reason — same package, different shop.
--
-- All nullable and all optional: a card that names no app behaves exactly as it
-- did under 0085, and the client retries reads and writes without this group
-- when the migration has not been applied (`utils/meterSettingsStore.ts`,
-- `METER_OPTIONAL_COLUMN_GROUPS`), while telling the admin which migration is
-- missing rather than dropping the setting in silence.
-- ============================================================================

alter table public.meter_digital_settings
  add column if not exists leave_ehailing_app_id        text,
  add column if not exists leave_ehailing_store_ios     text,
  add column if not exists leave_ehailing_store_android text,
  add column if not exists leave_ehailing_store_huawei  text;

comment on column public.meter_digital_settings.leave_ehailing_app_id is
  'Catalogue id of the dispatch app the e-hailing key opens (expo/utils/meterLeaveApps.ts). Null for a hand-entered link.';
comment on column public.meter_digital_settings.leave_ehailing_store_ios is
  'App Store page for that app, offered to an iPhone that does not have it.';
comment on column public.meter_digital_settings.leave_ehailing_store_android is
  'Google Play page for that app. Derived from the package id when the catalogue knows it.';
comment on column public.meter_digital_settings.leave_ehailing_store_huawei is
  'Huawei AppGallery page for that app, for HMS devices with no Play Store.';
