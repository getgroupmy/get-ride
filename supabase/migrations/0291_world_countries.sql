-- ============================================================================
-- 0291 — Admin › Country / States / Cities lists every country in the world.
--
-- public.regions_add_world_countries() adds the 249 countries and
-- territories of ISO 3166-1 to public.countries, each with its two-letter
-- code (values.isoCode). A country GET.ride doesn't serve yet comes in
-- Blocked for pickups and drop-offs (values.blockAt "both", values.blocked
-- true, migration 0212), so nothing changes for riders or drivers: a place
-- in no listed country was outside the service before, and a place in a
-- blocked one is outside it now. The admin opens a country by setting its
-- Block to None.
--
-- Countries already listed are left exactly as they are, matched by code,
-- name or the short names the list already uses (UAE, Vietnam, South Korea,
-- Hong Kong, Taiwan, Turkey ...); they only gain values.isoCode where they
-- have none.
--
-- Run here only where the admin has listed at least one country. With none
-- listed every place is served (ride_point_gap, coverageGap), and a list of
-- blocked countries would close the service everywhere.
--
-- Re-runnable: rows are added only where no country of that code or name is
-- listed, and an isoCode is only filled where it is missing.
-- ============================================================================

-- The number of countries added.
create or replace function public.regions_add_world_countries()
returns integer
language plpgsql
set search_path = public
as $$
declare
  v_added integer;
begin
  with world (iso, name, aliases) as (values
    ('AF', 'Afghanistan', '{}'),
    ('AX', 'Åland Islands', '{"Aland Islands"}'),
    ('AL', 'Albania', '{}'),
    ('DZ', 'Algeria', '{}'),
    ('AS', 'American Samoa', '{}'),
    ('AD', 'Andorra', '{}'),
    ('AO', 'Angola', '{}'),
    ('AI', 'Anguilla', '{}'),
    ('AQ', 'Antarctica', '{}'),
    ('AG', 'Antigua and Barbuda', '{}'),
    ('AR', 'Argentina', '{}'),
    ('AM', 'Armenia', '{}'),
    ('AW', 'Aruba', '{}'),
    ('AU', 'Australia', '{}'),
    ('AT', 'Austria', '{}'),
    ('AZ', 'Azerbaijan', '{}'),
    ('BS', 'Bahamas', '{"The Bahamas"}'),
    ('BH', 'Bahrain', '{}'),
    ('BD', 'Bangladesh', '{}'),
    ('BB', 'Barbados', '{}'),
    ('BY', 'Belarus', '{}'),
    ('BE', 'Belgium', '{}'),
    ('BZ', 'Belize', '{}'),
    ('BJ', 'Benin', '{}'),
    ('BM', 'Bermuda', '{}'),
    ('BT', 'Bhutan', '{}'),
    ('BO', 'Bolivia', '{}'),
    ('BQ', 'Caribbean Netherlands', '{"Bonaire, Sint Eustatius and Saba"}'),
    ('BA', 'Bosnia and Herzegovina', '{}'),
    ('BW', 'Botswana', '{}'),
    ('BV', 'Bouvet Island', '{}'),
    ('BR', 'Brazil', '{}'),
    ('IO', 'British Indian Ocean Territory', '{}'),
    ('BN', 'Brunei', '{"Brunei Darussalam"}'),
    ('BG', 'Bulgaria', '{}'),
    ('BF', 'Burkina Faso', '{}'),
    ('BI', 'Burundi', '{}'),
    ('CV', 'Cape Verde', '{"Cabo Verde"}'),
    ('KH', 'Cambodia', '{}'),
    ('CM', 'Cameroon', '{}'),
    ('CA', 'Canada', '{}'),
    ('KY', 'Cayman Islands', '{}'),
    ('CF', 'Central African Republic', '{}'),
    ('TD', 'Chad', '{}'),
    ('CL', 'Chile', '{}'),
    ('CN', 'China', '{}'),
    ('CX', 'Christmas Island', '{}'),
    ('CC', 'Cocos (Keeling) Islands', '{"Cocos Islands"}'),
    ('CO', 'Colombia', '{}'),
    ('KM', 'Comoros', '{}'),
    ('CG', 'Congo', '{"Republic of the Congo"}'),
    ('CD', 'DR Congo', '{"Democratic Republic of the Congo"}'),
    ('CK', 'Cook Islands', '{}'),
    ('CR', 'Costa Rica', '{}'),
    ('CI', 'Côte d''Ivoire', '{"Ivory Coast","Cote d''Ivoire"}'),
    ('HR', 'Croatia', '{}'),
    ('CU', 'Cuba', '{}'),
    ('CW', 'Curaçao', '{"Curacao"}'),
    ('CY', 'Cyprus', '{}'),
    ('CZ', 'Czechia', '{"Czech Republic"}'),
    ('DK', 'Denmark', '{}'),
    ('DJ', 'Djibouti', '{}'),
    ('DM', 'Dominica', '{}'),
    ('DO', 'Dominican Republic', '{}'),
    ('EC', 'Ecuador', '{}'),
    ('EG', 'Egypt', '{}'),
    ('SV', 'El Salvador', '{}'),
    ('GQ', 'Equatorial Guinea', '{}'),
    ('ER', 'Eritrea', '{}'),
    ('EE', 'Estonia', '{}'),
    ('SZ', 'Eswatini', '{"Swaziland"}'),
    ('ET', 'Ethiopia', '{}'),
    ('FK', 'Falkland Islands', '{}'),
    ('FO', 'Faroe Islands', '{}'),
    ('FJ', 'Fiji', '{}'),
    ('FI', 'Finland', '{}'),
    ('FR', 'France', '{}'),
    ('GF', 'French Guiana', '{}'),
    ('PF', 'French Polynesia', '{}'),
    ('TF', 'French Southern Territories', '{}'),
    ('GA', 'Gabon', '{}'),
    ('GM', 'Gambia', '{"The Gambia"}'),
    ('GE', 'Georgia', '{}'),
    ('DE', 'Germany', '{}'),
    ('GH', 'Ghana', '{}'),
    ('GI', 'Gibraltar', '{}'),
    ('GR', 'Greece', '{}'),
    ('GL', 'Greenland', '{}'),
    ('GD', 'Grenada', '{}'),
    ('GP', 'Guadeloupe', '{}'),
    ('GU', 'Guam', '{}'),
    ('GT', 'Guatemala', '{}'),
    ('GG', 'Guernsey', '{}'),
    ('GN', 'Guinea', '{}'),
    ('GW', 'Guinea-Bissau', '{}'),
    ('GY', 'Guyana', '{}'),
    ('HT', 'Haiti', '{}'),
    ('HM', 'Heard Island and McDonald Islands', '{}'),
    ('VA', 'Vatican City', '{"Holy See"}'),
    ('HN', 'Honduras', '{}'),
    ('HK', 'Hong Kong', '{"Hong Kong SAR"}'),
    ('HU', 'Hungary', '{}'),
    ('IS', 'Iceland', '{}'),
    ('IN', 'India', '{}'),
    ('ID', 'Indonesia', '{}'),
    ('IR', 'Iran', '{}'),
    ('IQ', 'Iraq', '{}'),
    ('IE', 'Ireland', '{}'),
    ('IM', 'Isle of Man', '{}'),
    ('IL', 'Israel', '{}'),
    ('IT', 'Italy', '{}'),
    ('JM', 'Jamaica', '{}'),
    ('JP', 'Japan', '{}'),
    ('JE', 'Jersey', '{}'),
    ('JO', 'Jordan', '{}'),
    ('KZ', 'Kazakhstan', '{}'),
    ('KE', 'Kenya', '{}'),
    ('KI', 'Kiribati', '{}'),
    ('KP', 'North Korea', '{}'),
    ('KR', 'South Korea', '{"Korea","Republic of Korea"}'),
    ('KW', 'Kuwait', '{}'),
    ('KG', 'Kyrgyzstan', '{}'),
    ('LA', 'Laos', '{}'),
    ('LV', 'Latvia', '{}'),
    ('LB', 'Lebanon', '{}'),
    ('LS', 'Lesotho', '{}'),
    ('LR', 'Liberia', '{}'),
    ('LY', 'Libya', '{}'),
    ('LI', 'Liechtenstein', '{}'),
    ('LT', 'Lithuania', '{}'),
    ('LU', 'Luxembourg', '{}'),
    ('MO', 'Macao', '{"Macau"}'),
    ('MG', 'Madagascar', '{}'),
    ('MW', 'Malawi', '{}'),
    ('MY', 'Malaysia', '{}'),
    ('MV', 'Maldives', '{}'),
    ('ML', 'Mali', '{}'),
    ('MT', 'Malta', '{}'),
    ('MH', 'Marshall Islands', '{}'),
    ('MQ', 'Martinique', '{}'),
    ('MR', 'Mauritania', '{}'),
    ('MU', 'Mauritius', '{}'),
    ('YT', 'Mayotte', '{}'),
    ('MX', 'Mexico', '{}'),
    ('FM', 'Micronesia', '{}'),
    ('MD', 'Moldova', '{}'),
    ('MC', 'Monaco', '{}'),
    ('MN', 'Mongolia', '{}'),
    ('ME', 'Montenegro', '{}'),
    ('MS', 'Montserrat', '{}'),
    ('MA', 'Morocco', '{}'),
    ('MZ', 'Mozambique', '{}'),
    ('MM', 'Myanmar', '{"Burma"}'),
    ('NA', 'Namibia', '{}'),
    ('NR', 'Nauru', '{}'),
    ('NP', 'Nepal', '{}'),
    ('NL', 'Netherlands', '{"The Netherlands"}'),
    ('NC', 'New Caledonia', '{}'),
    ('NZ', 'New Zealand', '{}'),
    ('NI', 'Nicaragua', '{}'),
    ('NE', 'Niger', '{}'),
    ('NG', 'Nigeria', '{}'),
    ('NU', 'Niue', '{}'),
    ('NF', 'Norfolk Island', '{}'),
    ('MK', 'North Macedonia', '{"Macedonia"}'),
    ('MP', 'Northern Mariana Islands', '{}'),
    ('NO', 'Norway', '{}'),
    ('OM', 'Oman', '{}'),
    ('PK', 'Pakistan', '{}'),
    ('PW', 'Palau', '{}'),
    ('PS', 'Palestine', '{}'),
    ('PA', 'Panama', '{}'),
    ('PG', 'Papua New Guinea', '{}'),
    ('PY', 'Paraguay', '{}'),
    ('PE', 'Peru', '{}'),
    ('PH', 'Philippines', '{"The Philippines"}'),
    ('PN', 'Pitcairn Islands', '{"Pitcairn"}'),
    ('PL', 'Poland', '{}'),
    ('PT', 'Portugal', '{}'),
    ('PR', 'Puerto Rico', '{}'),
    ('QA', 'Qatar', '{}'),
    ('RE', 'Réunion', '{"Reunion"}'),
    ('RO', 'Romania', '{}'),
    ('RU', 'Russia', '{"Russian Federation"}'),
    ('RW', 'Rwanda', '{}'),
    ('BL', 'Saint Barthélemy', '{"Saint Barthelemy"}'),
    ('SH', 'Saint Helena, Ascension and Tristan da Cunha', '{"Saint Helena"}'),
    ('KN', 'Saint Kitts and Nevis', '{}'),
    ('LC', 'Saint Lucia', '{}'),
    ('MF', 'Saint Martin', '{}'),
    ('PM', 'Saint Pierre and Miquelon', '{}'),
    ('VC', 'Saint Vincent and the Grenadines', '{}'),
    ('WS', 'Samoa', '{}'),
    ('SM', 'San Marino', '{}'),
    ('ST', 'São Tomé and Príncipe', '{"Sao Tome and Principe"}'),
    ('SA', 'Saudi Arabia', '{}'),
    ('SN', 'Senegal', '{}'),
    ('RS', 'Serbia', '{}'),
    ('SC', 'Seychelles', '{}'),
    ('SL', 'Sierra Leone', '{}'),
    ('SG', 'Singapore', '{}'),
    ('SX', 'Sint Maarten', '{}'),
    ('SK', 'Slovakia', '{}'),
    ('SI', 'Slovenia', '{}'),
    ('SB', 'Solomon Islands', '{}'),
    ('SO', 'Somalia', '{}'),
    ('ZA', 'South Africa', '{}'),
    ('GS', 'South Georgia and the South Sandwich Islands', '{}'),
    ('SS', 'South Sudan', '{}'),
    ('ES', 'Spain', '{}'),
    ('LK', 'Sri Lanka', '{}'),
    ('SD', 'Sudan', '{}'),
    ('SR', 'Suriname', '{}'),
    ('SJ', 'Svalbard and Jan Mayen', '{}'),
    ('SE', 'Sweden', '{}'),
    ('CH', 'Switzerland', '{}'),
    ('SY', 'Syria', '{}'),
    ('TW', 'Taiwan', '{}'),
    ('TJ', 'Tajikistan', '{}'),
    ('TZ', 'Tanzania', '{}'),
    ('TH', 'Thailand', '{}'),
    ('TL', 'Timor-Leste', '{"East Timor"}'),
    ('TG', 'Togo', '{}'),
    ('TK', 'Tokelau', '{}'),
    ('TO', 'Tonga', '{}'),
    ('TT', 'Trinidad and Tobago', '{}'),
    ('TN', 'Tunisia', '{}'),
    ('TR', 'Turkey', '{"Türkiye","Turkiye"}'),
    ('TM', 'Turkmenistan', '{}'),
    ('TC', 'Turks and Caicos Islands', '{}'),
    ('TV', 'Tuvalu', '{}'),
    ('UG', 'Uganda', '{}'),
    ('UA', 'Ukraine', '{}'),
    ('AE', 'United Arab Emirates', '{"UAE"}'),
    ('GB', 'United Kingdom', '{"UK","Great Britain"}'),
    ('US', 'United States', '{"USA","United States of America"}'),
    ('UM', 'United States Minor Outlying Islands', '{}'),
    ('UY', 'Uruguay', '{}'),
    ('UZ', 'Uzbekistan', '{}'),
    ('VU', 'Vanuatu', '{}'),
    ('VE', 'Venezuela', '{}'),
    ('VN', 'Vietnam', '{"Viet Nam"}'),
    ('VG', 'British Virgin Islands', '{}'),
    ('VI', 'U.S. Virgin Islands', '{"US Virgin Islands"}'),
    ('WF', 'Wallis and Futuna', '{}'),
    ('EH', 'Western Sahara', '{}'),
    ('YE', 'Yemen', '{}'),
    ('ZM', 'Zambia', '{}'),
    ('ZW', 'Zimbabwe', '{}')
  ),
  -- Which listed country each one already is: by its code, its name or one
  -- of its other names.
  listed as (
    select w.iso, c.id
      from world w
      join public.countries c
        on upper(coalesce(c.values->>'isoCode', '')) = w.iso
        or lower(btrim(c.name)) = lower(w.name)
        or lower(btrim(c.name)) = any (select lower(a) from unnest(w.aliases::text[]) a)
  ),
  -- Listed already: the code where it has none.
  coded as (
    update public.countries c
       set values = c.values || jsonb_build_object('isoCode', l.iso)
      from listed l
     where c.id = l.id
       and coalesce(c.values->>'isoCode', '') = ''
    returning c.id
  ),
  -- The rest, blocked until the admin opens them, after the listed ones A-Z.
  added as (
    insert into public.countries (name, values, position)
    select w.name,
           jsonb_build_object('isoCode', w.iso, 'blockAt', 'both', 'blocked', true),
           1000 + 10 * (row_number() over (order by w.name))::int
      from world w
     where not exists (select 1 from listed l where l.iso = w.iso)
    returning id
  )
  select count(*) into v_added from added;
  return v_added;
end;
$$;

revoke all on function public.regions_add_world_countries() from public, anon, authenticated;

comment on function public.regions_add_world_countries() is
  'Adds the ISO 3166-1 countries missing from public.countries, blocked until opened (0291). Returns how many were added.';

do $$
begin
  if exists (select 1 from public.countries) then
    perform public.regions_add_world_countries();
  end if;
end $$;

notify pgrst, 'reload schema';

insert into supabase_migrations.schema_migrations (version, name)
values ('20261025090000', '0291_world_countries')
on conflict do nothing;
