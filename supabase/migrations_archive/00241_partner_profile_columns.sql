-- Adds profile columns needed for the user-facing Partner onboarding flow.
-- Service area + multi-select partner types + auth user link are stored on the
-- partners row so it can be resumed across devices.

alter table public.partners
  add column if not exists service_countries text[] not null default '{}',
  add column if not exists service_states    text[] not null default '{}',
  add column if not exists service_cities    text[] not null default '{}',
  add column if not exists partner_types     text[] not null default '{}',
  add column if not exists avatar_url        text,
  add column if not exists address           text,
  add column if not exists onboarding_step   text;

create index if not exists partners_auth_user_idx on public.partners(auth_user_id);

-- Force PostgREST to reload its schema cache so the new columns are immediately
-- visible to the client (otherwise inserts fail with "Could not find the 'address'
-- column of 'partners' in the schema cache").
notify pgrst, 'reload schema';
