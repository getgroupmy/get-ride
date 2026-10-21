-- ============================================================================
-- 0265 — Place types: mall names the guess knew nothing of.
--
-- 0264's name rules sent most malls without "mall" in the name to Other
-- (ION Orchard, Pavilion Kuala Lumpur, Sunway Pyramid, VivoCity...), and
-- "Shopping Park" / "Gardens Mall" to Park, as the park rule came first.
-- The rules now look for shopping words ("mall", "shopping", "outlet")
-- before the park rule, and the mall rule knows the usual mall names
-- (Pavilion, Pyramid, City, Point, Central, Junction, Parade, Complex...).
-- lib/src/core/place_types.dart (placeTypeNameRules) has the same rules.
--
-- Only the guess changes: places already typed keep their type (the live
-- places were set by the admin after 0264).
-- ============================================================================

create or replace function public.place_type_name_rules()
returns table (key text, pat text)
language sql
immutable
set search_path = public
as $$
  select r.key, p.pat
    from (values
      (1,  'airport',                 array[' klia', ' airport', ' lapangan terbang', ' aerodrome', ' lcct ']),
      (2,  'ferry_terminal',          array[' ferry', ' feri ', ' jetty', ' jeti ']),
      (3,  'bus_station',             array[' bus ', ' bas ', ' tbs ', ' terminal bersepadu', ' hentian ', ' puduraya']),
      (4,  'subway_station',          array[' mrt ', ' lrt ', ' monorail']),
      (5,  'train_station',           array[' sentral', ' ktm ', ' station', ' stesen ', ' erl ', ' ets ']),
      (6,  'hospital',                array[' hospital', ' medical', ' clinic', ' klinik', ' perubatan']),
      (7,  'university',              array[' university', ' universiti', ' college', ' school', ' kolej', ' sekolah',
                                            ' politeknik', ' campus', ' kampus']),
      (8,  'mosque',                  array[' masjid', ' mosque', ' temple', ' church', ' kuil', ' surau', ' gereja',
                                            ' tokong', ' gurdwara']),
      (9,  'market',                  array[' pasar', ' market']),
      (10, 'local_government_office', array[' jabatan', ' kementerian', ' majlis', ' dewan bandaraya', ' dbkl ', ' jpj ',
                                            ' imigresen', ' immigration', ' government', ' city hall', ' mahkamah',
                                            ' balai polis', ' police']),
      (11, 'lodging',                 array[' hotel', ' resort', ' hostel', ' inn ']),
      (12, 'stadium',                 array[' stadium', ' arena']),
      (13, 'convention_center',       array[' convention', ' exhibition', ' auditorium', ' expo ']),
      (14, 'tourist_attraction',      array[' museum', ' muzium', ' zoo ', ' aquarium', ' aquaria', ' theme park']),
      -- Shopping words before the park rule: "Shopping Park", "Gardens Mall".
      (15, 'shopping_mall',           array['mall', ' shopping', ' outlet']),
      (16, 'park',                    array[' park ', ' tasik ', ' gardens', ' botanical']),
      (17, 'corporate_office',        array[' tower', ' menara', ' office', ' wisma ']),
      (18, 'shopping_mall',           array[' plaza', ' centre', ' center', ' square', ' galleria', ' klcc ', ' aeon ',
                                            ' pavilion', ' pyramid', ' city ', ' point ', ' central ', ' junction ',
                                            ' parade ', ' complex ', ' hub ', ' walk ', ' mytown ', ' utama ', ' vivocity',
                                            ' the curve ', ' trx ', ' ion orchard', ' paragon ', ' suntec ', ' bugis',
                                            ' funan ', ' jem ', ' westgate ', ' nex '])
    ) as r(n, key, pats)
    cross join lateral unnest(r.pats) with ordinality as p(pat, i)
   order by r.n, p.i;
$$;

notify pgrst, 'reload schema';
