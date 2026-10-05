-- Adds id_type to profiles so we can record the document type detected
-- during the ID-scan flow (passport / national_id / driver_license / other).
alter table public.profiles
  add column if not exists id_type text;

create index if not exists profiles_id_type_idx on public.profiles(id_type);

notify pgrst, 'reload schema';
