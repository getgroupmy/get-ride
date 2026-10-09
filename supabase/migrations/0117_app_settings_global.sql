-- 0117: App Settings, for every user (Admin → Settings → App Settings).
--
-- The admin page that used to keep the theme colours, splash background and
-- default start location on the admin's own device now saves them to the
-- single app_branding row every app already reads live (alongside the app
-- icon and splash picture). Each column is an override: null keeps what the
-- app draws by default, so nothing changes until an admin sets one.
--
--   splash_bg_light / splash_bg_dark  splash background per theme ('#RRGGBB')
--   theme                             {"light": {...}, "dark": {...}} colour
--                                     overrides (accent, primary, background,
--                                     text, textSecondary, border, error)
--   start_lat / start_lng             where maps open before a fix

alter table public.app_branding
  add column if not exists splash_bg_light text
    check (splash_bg_light is null or splash_bg_light ~ '^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})$'),
  add column if not exists splash_bg_dark text
    check (splash_bg_dark is null or splash_bg_dark ~ '^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})$'),
  add column if not exists theme jsonb not null default '{}'::jsonb
    check (jsonb_typeof(theme) = 'object'),
  add column if not exists start_lat double precision
    check (start_lat is null or start_lat between -90 and 90),
  add column if not exists start_lng double precision
    check (start_lng is null or start_lng between -180 and 180);

-- Both ends of the start location, or neither.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'app_branding_start_pair') then
    alter table public.app_branding
      add constraint app_branding_start_pair check ((start_lat is null) = (start_lng is null));
  end if;
end $$;

-- The row the apps read; created here so a fresh project has one to read.
-- (The Expo app's splash colour, set to the brand blue it falls back to.)
insert into public.app_branding (id, splash_bg_color) values ('global', '#2dabe2') on conflict (id) do nothing;
