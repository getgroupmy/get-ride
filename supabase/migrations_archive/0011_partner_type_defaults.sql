-- ============================================================================
-- 0011_partner_type_defaults.sql
-- Seeds the canonical 7 default partner types into settings_entries and tags
-- each with isDefault=true so the admin UI prevents deletion. Default rows
-- can still be edited (name, enabled, sub-services, priority); to remove one
-- you must delete it directly from Supabase (or unset isDefault first).
-- Safe to re-run: only inserts the missing names; existing rows are left alone
-- except that any row whose name matches a default has isDefault forced true.
-- ============================================================================

with defaults(name, sub_enabled, priority) as (
  values
    ('Dealer',           false, 1),
    ('Delivery',         true,  2),
    ('eHailing',         false, 3),
    ('Fleet',            false, 4),
    ('pHailing',         false, 5),
    ('Service Provider', true,  6),
    ('Teksi',            false, 7)
)
insert into public.settings_entries (category, position, values)
select
  'partner-type',
  d.priority,
  jsonb_build_object(
    'name', d.name,
    'enabled', true,
    'subServicesEnabled', d.sub_enabled,
    'subServicesJson', '[]',
    'displayPriority', d.priority,
    'isDefault', true
  )
from defaults d
where not exists (
  select 1
  from public.settings_entries e
  where e.category = 'partner-type'
    and lower(e.values->>'name') = lower(d.name)
);

-- Force isDefault=true on any existing row that matches a default name so
-- legacy installs (which seeded without the flag) become non-deletable.
update public.settings_entries e
set values = e.values || jsonb_build_object('isDefault', true)
where e.category = 'partner-type'
  and lower(e.values->>'name') in (
    'dealer','delivery','ehailing','fleet','phailing','service provider','teksi'
  )
  and coalesce((e.values->>'isDefault')::boolean, false) = false;
