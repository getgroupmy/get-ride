-- Destructive: drops everything created by schema.sql. Use with care.
drop trigger if exists on_auth_user_created on auth.users;

drop table if exists public.rides             cascade;
drop table if exists public.partner_documents cascade;
drop table if exists public.partners          cascade;
drop table if exists public.profiles          cascade;
drop table if exists public.settings_entries  cascade;
drop table if exists public.app_settings      cascade;

drop function if exists public.handle_new_auth_user() cascade;
drop function if exists public.set_updated_at()       cascade;

drop type if exists partner_status cascade;
drop type if exists permit_status  cascade;
drop type if exists user_status    cascade;
drop type if exists gender_type    cascade;

-- Storage buckets are intentionally NOT dropped to avoid losing uploads.
-- To drop: delete from storage.buckets where id in ('avatars','partner-documents','app-assets','ride-attachments');
