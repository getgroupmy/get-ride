-- ============================================================================
-- 0292 — Phone numbers and sign-in, per country (Admin › Country / States /
-- Cities › a country › Phone numbers and sign-in).
--
-- 1. country_phone_rules: one row per country (ISO code), filled from
--    Google's libphonenumber data (v8.13.55): dial code, shortest and
--    longest mobile number (digits after the dial code, no leading 0), the
--    digits mobile numbers start with, and whether only mobiles may get a
--    code. `defaults` keeps the data's values for "Fill from phone number
--    data". `access`: allowed / registration_closed / blocked. A daily code
--    limit (codes queued to the country's numbers per Malaysian day), with a
--    push to the admins at 80%. Countries GET.ride doesn't serve yet (blocked
--    for rides by 0291) start at 50 a day; served ones have no limit.
-- 2. phone_number_blocks: numbers of a country blocked by their first digits,
--    a range or the exact number; such a number can't sign up or sign in.
-- 3. otp_safe_numbers: test and staff numbers that skip every rule here and
--    the daily limit (Admin › Messaging).
-- 4. phone_rule_check(phone, new): the rule a number breaks, or null. The
--    number's country is the longest dial code it starts with; where codes
--    are shared (+1, +7, +44 ...) the country whose mobile digits it starts
--    with, else the code's main country. Checked by
--      - profile_phone_lookup (the phone screen): blocked for everyone; for a
--        number with no account also its length, mobile digits and
--        registration_closed;
--      - before_user_created_hook (no account made) and send_sms_hook (no
--        code sent; the daily limit counts here);
--      - pin_check (PIN sign-in) and session_is_current (signed in already:
--        a blocked number is signed out at the next check).
--    Errors read "<CODE>: <words>" so an app from before shows the words.
--
-- Re-runnable: tables and indexes "if not exists", functions "create or
-- replace", rows "on conflict do nothing", policies dropped first.
-- ============================================================================

-- ---- 1. Rules per country ---------------------------------------------------------------------------
create table if not exists public.country_phone_rules (
  iso               text primary key check (iso ~ '^[A-Z]{2}$'),
  dial_code         text not null check (dial_code ~ '^\+[0-9]{1,4}$'),
  dial_main         boolean not null default false,
  mobile_min        integer check (mobile_min between 3 and 17),
  mobile_max        integer check (mobile_max between 3 and 17 and mobile_max >= mobile_min),
  mobile_prefixes   text[] not null default '{}',
  mobile_only       boolean not null default true,
  access            text not null default 'allowed'
                      check (access in ('allowed', 'registration_closed', 'blocked')),
  daily_code_limit  integer check (daily_code_limit is null or daily_code_limit >= 0),
  alerted_on        date,
  defaults          jsonb not null default '{}',
  updated_at        timestamptz not null default now(),
  updated_by        uuid
);
create index if not exists country_phone_rules_dial on public.country_phone_rules (dial_code);

alter table public.country_phone_rules enable row level security;
-- The phone screen lists the countries (anyone may read them).
drop policy if exists country_phone_rules_read on public.country_phone_rules;
create policy country_phone_rules_read on public.country_phone_rules for select to anon, authenticated using (true);
grant select on public.country_phone_rules to anon, authenticated;
revoke insert, update, delete on public.country_phone_rules from anon, authenticated;

insert into public.country_phone_rules (iso, dial_code, dial_main, mobile_min, mobile_max, mobile_prefixes, mobile_only, defaults, daily_code_limit)
select v.iso, v.dial, v.main, v.mn, v.mx, v.pre::text[], v.mob,
       jsonb_build_object('min', v.mn, 'max', v.mx, 'prefixes', to_jsonb(v.pre::text[]), 'mobileOnly', v.mob),
       -- Served countries (open for rides) have no limit; the rest 50 a day.
       case when exists (select 1 from public.countries c
                          where upper(c.values->>'isoCode') = v.iso
                            and not public.region_blocks(c.values, true)) then null else 50 end
  from (values
    ('AF', '+93', false, 9, 9, '{7}', true),
    ('AX', '+358', false, 6, 10, '{4,50}', true),
    ('AL', '+355', false, 9, 9, '{69,672,673,674,675,676,677,678,679,682,683,684,685,686,687,688,689}', true),
    ('DZ', '+213', false, 9, 9, '{55,65,66,69,77,78,79,540,541,542,549,560,561,562,563,670,671,672,673,674,675,676}', true),
    ('AS', '+1', false, 10, 10, '{684}', true),
    ('AD', '+376', false, 6, 9, '{3,5,6}', true),
    ('AO', '+244', false, 9, 9, '{91,92,93,94,95,96,97,99}', true),
    ('AI', '+1', false, 10, 10, '{264}', true),
    ('AG', '+1', false, 10, 10, '{268}', true),
    ('AR', '+54', false, 10, 11, '{675,911,922,923,924,926,928,929,933,934,935,936,937,938}', true),
    ('AM', '+374', false, 8, 8, '{33,41,43,44,49,55,77,88,91,93,94,95,96,97,98,99}', true),
    ('AW', '+297', false, 7, 7, '{56,59,66,69,73,74,290,600,622,630,640,641,642,770,777,964,965,994,995,996,997,998}', true),
    ('AU', '+61', true, 9, 9, '{4}', true),
    ('AT', '+43', false, 7, 13, '{67,68,69,650,651,652,653,655,657,659,660,661,663,664,665,666,667,668,669}', true),
    ('AZ', '+994', false, 9, 9, '{10,40,44,50,51,55,60,70,77,99,365}', true),
    ('BS', '+1', false, 10, 10, '{242}', true),
    ('BH', '+973', false, 8, 8, '{3,630,633,636,644,663,666,667,669}', true),
    ('BD', '+880', false, 10, 10, '{11,13,14,15,16,17,18,19,370,372,373,374,375,376,377,378,379,380,382,383,384,385,386,387,388,389,440,442,443,444,445,446,447,448,449,644,660,662,663,664,665,666,667,668,669}', true),
    ('BB', '+1', false, 10, 10, '{246}', true),
    ('BY', '+375', false, 9, 9, '{33,44,255,256,257,259,291,292,293,294,295,296,297,298,299}', true),
    ('BE', '+32', false, 9, 9, '{45,46,47,48,49}', true),
    ('BZ', '+501', false, 7, 7, '{60,61,62,63,65,66,67}', true),
    ('BJ', '+229', false, 8, 10, '{5,6,40,41,42,43,44,45,46,47,48,90,91,93,94,95,96,97,98,99,012,014,015,016,019}', true),
    ('BM', '+1', false, 10, 10, '{441}', true),
    ('BT', '+975', false, 8, 8, '{16,17,77}', true),
    ('BO', '+591', false, 8, 8, '{6,7}', true),
    ('BQ', '+599', false, 7, 7, '{78,318,319,416,700,701,770,777,790,795,796}', true),
    ('BA', '+387', false, 8, 9, '{61,62,63,65,66,67,603,604,644}', true),
    ('BW', '+267', false, 8, 8, '{71,72,73,74,75,76,77,78,321}', true),
    ('BR', '+55', false, 10, 11, '{117,119,127,129,137,139,147,149,157,159,167,169,177,179,187,189,197,199,217,219,227,229,247,249,277,279,287,289,317,319,327,329,337,339,347,349,357,359,377,379,387,389,417,419,427,429,437,439,447,449,457,459,467,469,477,479,487,489,497,499,517,519,537,539,547,549,557,559,617,619,627,629,637,639,647,649,657,659,667,669,677,679,687,689,697,699,717,719,737,739,747,749,757,759,777,779,797,799,817,819,827,829,837,839,847,849,857,859,867,869,877,879,887,889,897,899,917,919,927,929,937,939,947,949,957,959,967,969,977,979,987,989,997,999}', true),
    ('IO', '+246', false, 7, 7, '{38}', true),
    ('BN', '+673', false, 7, 7, '{7,8,228,229}', true),
    ('BG', '+359', false, 8, 9, '{87,88,89,98,430,437,438,439,996,999}', true),
    ('BF', '+226', false, 8, 8, '{6,7,01,02,03,04,05,06,07,50,51,52,53,54,55,56,57,58}', true),
    ('BI', '+257', false, 8, 8, '{29,61,62,65,66,67,68,69,71,72,75,76,77,78,79}', true),
    ('CV', '+238', false, 7, 7, '{9,36,51,52,53,58,59}', true),
    ('KH', '+855', false, 8, 9, '{1,6,7,9,31,38,80,81,83,84,85,86,87,88,89,234,244,254,264,324,334,344,354,364,424,434,444,524,534,544,554}', true),
    ('CM', '+237', false, 9, 9, '{62,65,66,67,68,69,242,243,640}', true),
    ('CA', '+1', false, 10, 10, '{}', false),
    ('KY', '+1', false, 10, 10, '{345}', true),
    ('CF', '+236', false, 8, 8, '{70,72,74,75,76,77}', true),
    ('TD', '+235', false, 8, 8, '{6,9,77,85,86}', true),
    ('CL', '+56', false, 9, 9, '{}', false),
    ('CN', '+86', false, 11, 11, '{13,18,145,147,150,151,152,153,155,156,157,158,159,162,165,166,167,170,171,172,173,174,175,176,177,178,190,191,192,193,195,196,197,198,199}', true),
    ('CX', '+61', false, 9, 9, '{4}', true),
    ('CC', '+61', false, 9, 9, '{4}', true),
    ('CO', '+57', false, 10, 10, '{31,300,301,302,303,304,305,320,321,322,323,324,330,333,350,351,370,910}', true),
    ('KM', '+269', false, 7, 7, '{3,4}', true),
    ('CG', '+242', false, 9, 9, '{01,04,05,06,024,025,026}', true),
    ('CD', '+243', false, 7, 9, '{80,81,82,83,84,85,86,88,89,90,91,97,98,99}', true),
    ('CK', '+682', false, 5, 5, '{5,7,8}', true),
    ('CR', '+506', false, 8, 8, '{50,57,60,61,62,63,64,70,71,72,73,83,84,85,86,87,88,89,300,650}', true),
    ('CI', '+225', false, 10, 10, '{01,05,07}', true),
    ('HR', '+385', false, 8, 9, '{91,92,95,98,99,901,902,903,904,905,906,907,908,909,970,975,976,977,979}', true),
    ('CU', '+53', false, 8, 8, '{5,62,63,64}', true),
    ('CW', '+599', true, 7, 8, '{951,952,953,954,956,957,965,966,967,968,969}', true),
    ('CY', '+357', false, 8, 8, '{94,95,96,97,99,910}', true),
    ('CZ', '+420', false, 9, 9, '{72,73,77,79,601,602,603,604,605,606,607,608,702,703,704,705,706,719}', true),
    ('DK', '+45', false, 8, 8, '{2,3,4,5,6,7,96,811,812,813,814,815,816,817,818,819,821,822,823,824,825,826,827,828,829,861,862,863,864,865,866,867,868,869,871,872,873,874,875,876,877,878,879,881,882,883,884,885,886,887,888,889,891,892,893,894,895,896,897,898,899,911,912,913,914,915,916,917,918,919,921,922,923,924,925,926,927,928,929,931,932,933,934,935,936,937,938,939,941,942,943,944,945,946,947,948,949,971,972,973,974,975,976,977,978,979,981,982,983,984,985,986,987,988,989,991,992,993,994,995,996,997,998,999}', true),
    ('DJ', '+253', false, 8, 8, '{77}', true),
    ('DM', '+1', false, 10, 10, '{767}', true),
    ('DO', '+1', false, 10, 10, '{809,829,849}', true),
    ('EC', '+593', false, 9, 9, '{98,99,939,958,959,960,961,962,963,964,966,967,968,969,978,979}', true),
    ('EG', '+20', false, 10, 10, '{10,11,12,15}', true),
    ('SV', '+503', false, 8, 8, '{6,7}', true),
    ('GQ', '+240', false, 9, 9, '{55,222}', true),
    ('ER', '+291', false, 7, 7, '{7,171,172,173}', true),
    ('EE', '+372', false, 7, 8, '{5,82,83,84,89,810,811,812,813,814,815,816,817,819}', true),
    ('SZ', '+268', false, 8, 8, '{76,77,78,79}', true),
    ('ET', '+251', false, 9, 9, '{9,70,710,711,712,713,714,715,716,717,718,722,777,786,799}', true),
    ('FK', '+500', false, 5, 5, '{5,6}', true),
    ('FO', '+298', false, 6, 6, '{5,21,22,23,24,25,26,27,28,29,71,72,73,74,75,76,77,78,79,91,96}', true),
    ('FJ', '+679', false, 7, 7, '{2,7,9,45,50,51,55,56,58,80,83,84,86,87,89}', true),
    ('FI', '+358', true, 6, 10, '{4,50}', true),
    ('FR', '+33', false, 9, 9, '{6,73,74,75,76,77,78,79}', true),
    ('GF', '+594', false, 9, 9, '{694,709}', true),
    ('PF', '+689', false, 8, 8, '{87,88,89}', true),
    ('GA', '+241', false, 7, 8, '{2,3,4,5,6,7,02,03,04,05,06,07}', true),
    ('GM', '+220', false, 7, 7, '{2,3,6,7,9,40,41,45,50,51,52,53,54,58,59}', true),
    ('GE', '+995', false, 9, 9, '{5,790}', true),
    ('DE', '+49', false, 10, 11, '{17,150,151,152,153,155,156,157,158,159,160,162,163}', true),
    ('GH', '+233', false, 9, 9, '{20,23,24,26,27,28,29,50,53,54,55,56,57,256,257,591,592,593,594,595,596,597,598,599}', true),
    ('GI', '+350', false, 8, 8, '{51,54,56,57,58,525,601,606}', true),
    ('GR', '+30', false, 10, 10, '{69,94,685,687,688,689}', true),
    ('GL', '+299', false, 6, 6, '{2,4,5}', true),
    ('GD', '+1', false, 10, 10, '{473}', true),
    ('GP', '+590', true, 9, 9, '{690,691,694,696,709}', true),
    ('GU', '+1', false, 10, 10, '{}', false),
    ('GT', '+502', false, 8, 8, '{3,4,5,800,801,802,803,804}', true),
    ('GG', '+44', false, 10, 10, '{778,783,791}', true),
    ('GN', '+224', false, 9, 9, '{60,61,62,63,65,66}', true),
    ('GW', '+245', false, 9, 9, '{95,965,966,969,977}', true),
    ('GY', '+592', false, 7, 7, '{6,70,71,72,73,74,75,510}', true),
    ('HT', '+509', false, 8, 8, '{3,4,55}', true),
    ('VA', '+39', false, 9, 10, '{31,32,33,34,35,36,37,38,39}', true),
    ('HN', '+504', false, 8, 8, '{3,7,8,9}', true),
    ('HK', '+852', false, 8, 8, '{6,44,46,59,92,93,94,95,96,97,98,470,471,474,475,476,510,511,512,513,514,516,517,518,519,520,521,522,523,524,526,527,528,529,530,531,532,533,534,536,537,538,539,540,541,542,543,544,546,547,548,549,550,551,552,553,554,556,557,558,559,560,561,562,563,564,566,568,569,570,571,572,573,574,576,577,578,579,701,702,703,704,705,707,708,709,840,841,842,843,844,848,849,901,902,903,904,905,906,907,908,909,910,912,913,914,915,916,917,918,919}', true),
    ('HU', '+36', false, 9, 9, '{20,30,31,50,70}', true),
    ('IS', '+354', false, 7, 9, '{69,76,77,78,79,83,84,85,86,89,385,388,389,611,612,613,614,615,616,617,618,620,621,622,623,624,625,626,630,632,636,637,638,639,640,641,644,646,647,649,650,651,655,659,660,661,662,663,664,665,666,669,670,680,686,687,688,750,755,757,820,821,822,823,824,825,829,882,883,888}', true),
    ('IN', '+91', false, 10, 10, '{6,7,8,9}', true),
    ('ID', '+62', false, 9, 12, '{81,82,83,85,86,87,88,89}', true),
    ('IR', '+98', false, 10, 10, '{91,93,900,901,902,903,904,905,920,921,922,923,990,991,992,993,994,995,996,998,999}', true),
    ('IQ', '+964', false, 10, 10, '{73,74,75,76,77,78,79}', true),
    ('IE', '+353', false, 9, 9, '{83,85,86,87,88,89,822}', true),
    ('IM', '+44', false, 10, 10, '{745,752,762,792}', true),
    ('IL', '+972', false, 9, 9, '{53,56,500,502,503,504,505,506,507,508,509,510,512,513,514,515,516,517,518,519,520,522,523,524,525,526,527,528,529,542,543,544,545,546,547,548,549,550,552,553,554,555,556,557,558,559,583,584,585,586,587,592,593,594,595,596,597,598,599}', true),
    ('IT', '+39', true, 9, 10, '{31,32,33,34,35,36,37,38,39,43}', true),
    ('JM', '+1', false, 10, 10, '{658,876}', true),
    ('JP', '+81', false, 10, 10, '{60,701,702,703,704,705,706,707,708,709,801,802,803,804,805,806,807,808,809,901,902,903,904,905,906,907,908,909}', true),
    ('JE', '+44', false, 10, 10, '{750,770,779,782,793}', true),
    ('JO', '+962', false, 9, 9, '{79,770,771,772,775,776,777,778,779,780,781,782,785,786,787,788,789}', true),
    ('KZ', '+7', false, 10, 10, '{700,701,702,705,706,707,708,747,760,761,762,763,764,771,775,776,777,778,785}', true),
    ('KE', '+254', false, 9, 9, '{7,100,101,102,103,104,105,106,107,108,110,111,112,113,114,115,116,117,120,121,124,130}', true),
    ('KI', '+686', false, 8, 8, '{7,63,620}', true),
    ('KP', '+850', false, 10, 10, '{191,192,193}', true),
    ('KR', '+82', false, 9, 10, '{10,11,12,16,17,18,19}', true),
    ('KW', '+965', false, 8, 8, '{6,9,41,50,55,510,511,512,513,514,515,516,517,522,525,565,566,575,577,588}', true),
    ('KG', '+996', false, 9, 9, '{22,50,51,52,54,55,56,57,70,77,200,201,202,203,205,312,600,755,880,888,912,990,995,996,997,998,999}', true),
    ('LA', '+856', false, 10, 10, '{202,203,205,207,208,209,302,304}', true),
    ('LV', '+371', false, 8, 8, '{2}', true),
    ('LB', '+961', false, 7, 8, '{3,70,71,81,760,761,763,764,765,766,767,768,769,788,789,791,792,793}', true),
    ('LS', '+266', false, 8, 8, '{5,6}', true),
    ('LR', '+231', false, 7, 9, '{5,6,46,47,77,88,220,330,424}', true),
    ('LY', '+218', false, 9, 9, '{91,92,93,94,95,96}', true),
    ('LI', '+423', false, 7, 9, '{73,77,78,79,645,646,647,648,649,650,651,652,653,654,656,659,660,661,662,663,664,665,666,667,742,756}', true),
    ('LT', '+370', false, 8, 8, '{6}', true),
    ('LU', '+352', false, 9, 9, '{621,628,651,655,656,658,661,668,671,678,679,681,691,698}', true),
    ('MO', '+853', false, 8, 8, '{62,63,65,66,68}', true),
    ('MG', '+261', false, 9, 9, '{32,33,34,37,38,39}', true),
    ('MW', '+265', false, 9, 9, '{31,77,88,89,98,99,111}', true),
    ('MY', '+60', false, 9, 10, '{1}', true),
    ('MV', '+960', false, 7, 7, '{7,9,464,466}', true),
    ('ML', '+223', false, 8, 8, '{6,7,9,50,51,82,83,84,85,89,200,207,217}', true),
    ('MT', '+356', false, 8, 8, '{77,79,92,99,721,969,981,988,989}', true),
    ('MH', '+692', false, 7, 7, '{235,329,453,455,456,457,458,545}', true),
    ('MQ', '+596', false, 9, 9, '{696,697,709}', true),
    ('MR', '+222', false, 8, 8, '{20,21,22,23,24,26,27,28,29,30,31,32,33,34,36,37,38,39,40,41,42,43,44,46,47,48,49}', true),
    ('MU', '+230', false, 8, 8, '{55,57,58,525,526,527,528,529,542,543,544,545,546,547,548,549,590,591,592,593,594,595,596,597,598,700,701,702,703,704,730,731,733}', true),
    ('YT', '+262', false, 9, 9, '{639,709}', true),
    ('MX', '+52', false, 10, 10, '{22,33,44,45,55,56,72,77,81,96,99,231,232,233,235,236,237,238,241,243,244,245,246,247,248,249,271,272,273,274,275,276,278,279,281,282,283,284,285,287,288,294,296,297,311,312,313,314,315,316,317,319,321,322,323,324,325,326,327,328,329,341,342,343,344,345,346,347,348,349,351,352,353,354,355,356,357,358,359,371,372,373,374,375,376,377,378,381,382,383,384,385,386,387,388,389,391,392,393,394,395,411,412,413,414,415,417,418,419,421,422,423,424,425,426,427,428,429,431,432,433,434,435,436,437,438,461,462,463,464,465,466,467,468,469,471,472,473,474,475,476,477,478,479,481,482,483,485,486,487,488,489,492,493,494,495,496,498,499,588,591,592,593,594,595,596,597,599,612,613,614,615,616,618,621,622,623,624,625,626,627,628,629,631,632,633,634,635,636,637,638,639,641,642,643,644,645,646,647,648,649,651,652,653,656,657,658,659,660,661,662,663,664,665,667,668,669,671,672,673,674,675,676,677,686,687,694,695,696,697,698,711,712,713,714,715,716,717,718,719,731,732,733,734,735,736,737,738,739,741,742,743,744,745,746,747,748,749,751,753,754,755,756,757,758,759,761,762,763,764,765,766,767,768,769,781,782,783,784,785,786,789,791,797,821,823,824,825,826,828,829,831,832,833,834,835,836,841,842,844,845,846,861,862,864,866,867,868,869,870,871,872,873,877,878,891,892,894,897,899,913,914,916,917,918,919,921,922,923,924,932,933,934,936,937,938,951,953,954,958,971,972,981,982,983,984,985,986,987,988}', true),
    ('FM', '+691', false, 7, 7, '{92,93,94,95,96,97,310,312,313,320,330,350,360,370,380,390,820}', true),
    ('MD', '+373', false, 8, 8, '{6,71,76,77,78,79,562}', true),
    ('MC', '+377', false, 8, 9, '{3,6,44,46,49,451,452,453,454,455,456,457,458,459}', true),
    ('MN', '+976', false, 8, 8, '{9,50,55,60,66,69,72,80,81,85,86,88,89,830,831}', true),
    ('ME', '+382', false, 8, 8, '{60,67,68,69,630,632,634,660,661,662,665}', true),
    ('MS', '+1', false, 10, 10, '{664}', true),
    ('MA', '+212', true, 9, 9, '{6,70,71,76,77,720,721,722,723,724,726,727,750,751,752,753,780,781,782,783,784,785}', true),
    ('MZ', '+258', false, 9, 9, '{82,83,84,85,86,87,89}', true),
    ('MM', '+95', false, 7, 10, '{96,98,170,171,920,921,922,923,924,925,926,930,931,932,933,934,936,940,941,942,943,944,945,947,948,949,950,951,952,953,954,955,956,973,974,975,976,977,978,979,990,991,994,995,996,997,998,999}', true),
    ('NA', '+264', false, 9, 9, '{60,81,82,84,85}', true),
    ('NR', '+674', false, 7, 7, '{8,553,554,555,556,557,558,559,666}', true),
    ('NP', '+977', false, 10, 10, '{900,960,961,962,963,970,972,974,975,976,980,981,982,984,985,986,988}', true),
    ('NL', '+31', false, 9, 11, '{61,62,63,64,65,68,970}', true),
    ('NC', '+687', false, 6, 6, '{5,7,9,80,81,82,83,84,85,86,87,89}', true),
    ('NZ', '+64', false, 8, 10, '{20,21,22,26,27,28,29}', true),
    ('NI', '+505', false, 8, 8, '{8,57,58,75,76,77,78,550,551,552,553,554,555,556,557,620,630,633,635,640,644,645,650,655,677,681,682,683,684,685,686,687,688,689,690,695,699}', true),
    ('NE', '+227', false, 8, 8, '{8,9,23,70,74,76,77}', true),
    ('NG', '+234', false, 10, 10, '{71,72,81,701,702,703,704,705,706,707,708,709,801,802,803,804,805,806,807,808,809,901,902,903,904,905,906,907,908,909,911,912,913,914,915,916}', true),
    ('NU', '+683', false, 4, 7, '{5,6,888}', true),
    ('NF', '+672', false, 6, 6, '{14,35,38}', true),
    ('MK', '+389', false, 8, 8, '{7}', true),
    ('MP', '+1', false, 10, 10, '{}', false),
    ('NO', '+47', true, 8, 8, '{9,40,41,45,46,47,48}', true),
    ('OM', '+968', false, 8, 8, '{9,71,72,76,77,78,79,150}', true),
    ('PK', '+92', false, 10, 10, '{30,31,32,34,37,330,331,332,333,334,335,336,337,339,355,364}', true),
    ('PW', '+680', false, 7, 7, '{45,77,88,460,461,462,463,464,465,620,630,640,660,680,690,780,830,831,832,833,834,835}', true),
    ('PS', '+970', false, 9, 9, '{56,59}', true),
    ('PA', '+507', false, 7, 8, '{6,111,161,218,219,810,811,872,873}', true),
    ('PG', '+675', false, 8, 8, '{7,81,82,83,88}', true),
    ('PY', '+595', false, 9, 9, '{951,961,962,969,971,972,973,974,975,976,981,982,983,984,985,986,987,991,992,993,994,995}', true),
    ('PE', '+51', false, 9, 9, '{9}', true),
    ('PH', '+63', false, 10, 10, '{9,813,817,895,896,897,898}', true),
    ('PL', '+48', false, 9, 9, '{45,50,51,53,57,60,66,69,72,73,78,79,88,211,212,213}', true),
    ('PT', '+351', false, 9, 9, '{91,92,93,96,169,609,639,659,669,948}', true),
    ('PR', '+1', false, 10, 10, '{}', false),
    ('QA', '+974', false, 8, 8, '{3,5,6,7}', true),
    ('RE', '+262', true, 9, 9, '{692,693,709}', true),
    ('RO', '+40', false, 9, 9, '{7,62,600,630}', true),
    ('RU', '+7', true, 10, 10, '{9}', true),
    ('RW', '+250', false, 9, 9, '{72,73,77,78,79}', true),
    ('BL', '+590', false, 9, 9, '{690,691,694,696,709}', true),
    ('SH', '+290', true, 5, 5, '{5,6}', true),
    ('KN', '+1', false, 10, 10, '{869}', true),
    ('LC', '+1', false, 10, 10, '{758}', true),
    ('MF', '+590', false, 9, 9, '{690,691,694,696,709}', true),
    ('PM', '+508', false, 6, 9, '{40,42,43,44,48,49,50,52,53,54,55,56,57,58,59,708}', true),
    ('VC', '+1', false, 10, 10, '{784}', true),
    ('WS', '+685', false, 7, 10, '{71,72,73,75,76,77,83,84,85,86,87,89}', true),
    ('SM', '+378', false, 8, 8, '{61,66}', true),
    ('ST', '+239', false, 7, 7, '{90,98,99}', true),
    ('SA', '+966', false, 9, 9, '{50,51,53,54,55,56,57,58,59}', true),
    ('SN', '+221', false, 9, 9, '{70,75,76,77,78,710,721,790}', true),
    ('RS', '+381', false, 8, 10, '{6}', true),
    ('SC', '+248', false, 7, 7, '{21,22,25,26,27,28}', true),
    ('SL', '+232', false, 8, 8, '{25,30,31,32,33,34,35,66,72,73,74,75,76,77,78,79,80,88,90,99}', true),
    ('SG', '+65', false, 8, 8, '{8,90,91,92,93,94,95,96,97,98}', true),
    ('SX', '+1', false, 10, 10, '{721}', true),
    ('SK', '+421', false, 9, 9, '{95,901,902,903,904,905,906,907,908,909,910,911,912,914,915,916,917,918,919,940,943,944,945,947,948,949}', true),
    ('SI', '+386', false, 8, 8, '{30,31,40,41,43,49,51,64,68,69,70,71,651,655,656,657,658}', true),
    ('SB', '+677', false, 5, 7, '{48,68,69,71,72,73,74,75,76,77,78,79,84,85,86,87,88,89,94,96,912,913,914,915,916,917,918,919,920,921,923,924,925,926,927,928,929,930,931,932,950,951,952,953,954,956,957,958,959,970,971,972,973,974,975,976,978,979,980,981,982,983,984,985,986,987,989,990,991,992,993,994,995,996,997,998}', true),
    ('SO', '+252', false, 7, 9, '{6,7,15,24,28,35,39,48,49,80,88,90,92,93,94,95,96,97,98,99}', true),
    ('ZA', '+27', false, 5, 9, '{4,6,7,81,82,83,84,85,104,124,134,144,154,164,174,184,191,192,214,224,274,284,314,324,334,344,354,364,394,514,534,544,564,574,584,870,871,872,873}', true),
    ('SS', '+211', false, 9, 9, '{12,91,92,95,97,98,99}', true),
    ('ES', '+34', false, 9, 9, '{6,71,72,73,74,78,590,969,973}', true),
    ('LK', '+94', false, 9, 9, '{70,71,72,75,76,77,78,740,741,742,743,744}', true),
    ('SD', '+249', false, 9, 9, '{10,11,12,90,91,92,93,95,96,99}', true),
    ('SR', '+597', false, 7, 7, '{71,72,74,75,76,77,81,82,83,84,85,86,87,88,89}', true),
    ('SJ', '+47', false, 8, 8, '{9,40,41,45,46,47,48}', true),
    ('SE', '+46', false, 9, 9, '{70,72,73,76,79}', true),
    ('CH', '+41', false, 9, 9, '{68,69,72,73,75,76,77,78,79}', true),
    ('SY', '+963', false, 9, 9, '{50,91,92,93,94,95,96,98,99}', true),
    ('TW', '+886', false, 9, 9, '{90,91,92,93,94,95,96,97,98,400}', true),
    ('TJ', '+992', false, 9, 9, '{0,9,10,11,17,18,20,22,30,40,50,55,70,71,75,77,78,80,87,88,330,333,334,335,336,337,338,339,411,418,440,442,443,444,447,449,811,812,813,814,815,816,817,818,819}', true),
    ('TZ', '+255', false, 9, 9, '{61,62,65,66,67,68,69,71,73,74,75,76,77,78,79}', true),
    ('TH', '+66', false, 9, 9, '{8,9,14,61,62,63,64,65,66,671,672}', true),
    ('TL', '+670', false, 8, 8, '{72,73,74,75,76,77,78}', true),
    ('TG', '+228', false, 8, 8, '{70,71,72,79,90,91,92,93,96,97,98,99}', true),
    ('TK', '+690', false, 4, 7, '{72,73,74}', true),
    ('TO', '+676', false, 7, 7, '{7,60,69,84,86,87,88,89,540,541,542,543,544,545,554,555,556,630,632,681,685,686,687,688,689,999}', true),
    ('TT', '+1', false, 10, 10, '{868}', true),
    ('TN', '+216', false, 8, 8, '{2,5,9,40,41,42,43,44,45,46,47,48,300,311,312,313,314,315,324,360,361,362,363,364,391}', true),
    ('TR', '+90', false, 10, 10, '{53,54,501,505,506,507,510,516,524,551,552,553,554,555,559,561,594,596}', true),
    ('TM', '+993', false, 8, 8, '{6,71}', true),
    ('TC', '+1', false, 10, 10, '{649}', true),
    ('TV', '+688', false, 6, 7, '{70,71,90}', true),
    ('UG', '+256', false, 9, 9, '{7}', true),
    ('UA', '+380', false, 9, 9, '{39,50,63,66,67,68,71,72,73,75,77,91,92,93,94,95,96,97,98,99,790}', true),
    ('AE', '+971', false, 9, 9, '{50,52,54,55,56,58}', true),
    ('GB', '+44', true, 10, 10, '{71,72,73,74,75,77,78,79}', true),
    ('US', '+1', true, 10, 10, '{}', false),
    ('UY', '+598', false, 8, 8, '{91,92,93,94,95,96,97,98,99}', true),
    ('UZ', '+998', false, 9, 9, '{20,33,50,70,77,87,88,90,91,92,93,94,95,97,98,99,612,613,615,616,617,621,622,625,627,651,652,653,655,657,662,663,664,667,669,672,675,677,679,711,716,717,719,722,723,725,727,732,733,735,737,739,742,745,747,749,751,752,753,755,757,792,793,795,797}', true),
    ('VU', '+678', false, 7, 7, '{5,8,70,71,73,74,75,76,77}', true),
    ('VE', '+58', false, 10, 10, '{412,414,415,416,417,418,424,426}', true),
    ('VN', '+84', false, 9, 9, '{3,9,51,56,58,59,70,76,77,78,79,81,82,83,84,85,86,87,88,522,523,528,559,896,897,898,899}', true),
    ('VG', '+1', false, 10, 10, '{284}', true),
    ('VI', '+1', false, 10, 10, '{}', false),
    ('WF', '+681', false, 6, 6, '{72,82,83}', true),
    ('EH', '+212', false, 9, 9, '{6,70,71,76,77,720,721,722,723,724,726,727,750,751,752,753,780,781,782,783,784,785}', true),
    ('YE', '+967', false, 9, 9, '{70,71,73,77,78}', true),
    ('ZM', '+260', false, 9, 9, '{75,76,77,79,95,96,97,98}', true),
    ('ZW', '+263', false, 9, 9, '{71,72,77,78,731,732,733,734,735,736,737,738,739}', true)

  ) as v(iso, dial, main, mn, mx, pre, mob)
on conflict (iso) do nothing;

-- ---- 2. Blocked numbers ----------------------------------------------------------------------------
-- Digits after the dial code, without a leading 0 ("123", or from "1230000000" to "1239999999").
create table if not exists public.phone_number_blocks (
  id          uuid primary key default gen_random_uuid(),
  iso         text not null references public.country_phone_rules (iso) on delete cascade,
  kind        text not null check (kind in ('prefix', 'range', 'number')),
  value_from  text not null check (value_from ~ '^[0-9]{1,17}$'),
  value_to    text check (value_to is null or value_to ~ '^[0-9]{1,17}$'),
  note        text check (note is null or length(note) <= 200),
  created_by  uuid,
  created_at  timestamptz not null default now(),
  check ((kind = 'range') = (value_to is not null)),
  check (kind <> 'range' or (length(value_from) = length(value_to) and value_from <= value_to))
);
create index if not exists phone_number_blocks_iso on public.phone_number_blocks (iso);
alter table public.phone_number_blocks enable row level security;
drop policy if exists phone_number_blocks_read on public.phone_number_blocks;
create policy phone_number_blocks_read on public.phone_number_blocks for select to authenticated
  using ((select public.caller_admin_can_write('rpc:admin_phone_block_add')));
revoke insert, update, delete on public.phone_number_blocks from anon, authenticated;

-- ---- 3. Test and staff numbers ---------------------------------------------------------------------
create table if not exists public.otp_safe_numbers (
  phone       text primary key check (phone ~ '^\+[0-9]{6,17}$'),
  note        text check (note is null or length(note) <= 200),
  created_by  uuid,
  created_at  timestamptz not null default now(),
  last_used_at timestamptz
);
alter table public.otp_safe_numbers enable row level security;
drop policy if exists otp_safe_numbers_read on public.otp_safe_numbers;
create policy otp_safe_numbers_read on public.otp_safe_numbers for select to authenticated
  using ((select public.caller_admin_can_write('rpc:admin_otp_safe_set')));
revoke insert, update, delete on public.otp_safe_numbers from anon, authenticated;

-- Codes counted per country for the daily limit.
alter table public.sms_log add column if not exists country_iso text;
create index if not exists sms_log_country_time on public.sms_log (country_iso, created_at desc) where status = 'queued';

-- ---- 4. Checks -------------------------------------------------------------------------------------
-- The country rule for an E.164 number, with the national digits (no
-- leading 0). Null when no dial code matches.
create or replace function public.phone_country_rule(p_phone text)
returns table (r public.country_phone_rules, nsn text)
language sql
stable
security definer
set search_path = public
as $$
  with d as (select regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') as digits),
  best as (
    select max(length(c.dial_code) - 1) as len
      from public.country_phone_rules c, d
     where d.digits like substr(c.dial_code, 2) || '%'
  )
  select c, ltrim(substr(d.digits, best.len + 1), '0')
    from public.country_phone_rules c, d, best
   where best.len is not null
     and length(c.dial_code) - 1 = best.len
     and d.digits like substr(c.dial_code, 2) || '%'
   order by
     -- A shared code: the country whose mobile digits the number starts with.
     exists (select 1 from unnest(c.mobile_prefixes) p
              where ltrim(substr(d.digits, best.len + 1), '0') like p || '%') desc,
     c.dial_main desc,
     c.iso
   limit 1;
$$;
revoke execute on function public.phone_country_rule(text) from public, anon, authenticated;

-- Whether [p_phone] is a test or staff number.
create or replace function public.phone_is_safe(p_phone text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.otp_safe_numbers s
                  where s.phone = '+' || regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'));
$$;
revoke execute on function public.phone_is_safe(text) from public, anon, authenticated;

-- The rule [p_phone] breaks, as { code, country, iso, dial, min, max }, or
-- an empty object when it may go on. [p_new]: a number with no account yet,
-- checked for its length, mobile digits and closed registration too.
create or replace function public.phone_rule_check(p_phone text, p_new boolean)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_found record;
  v_rule public.country_phone_rules;
  v_nat  text;
  v_name text;
  v_code text;
begin
  if public.phone_is_safe(p_phone) then
    return '{}'::jsonb;
  end if;
  select * into v_found from public.phone_country_rule(p_phone);
  if v_found.r is null then
    return '{}'::jsonb;
  end if;
  v_rule := v_found.r;
  v_nat := v_found.nsn;
  if v_rule.iso is null then
    return '{}'::jsonb;
  end if;
  if v_rule.access = 'blocked'
     or exists (select 1 from public.phone_number_blocks b
                 where b.iso = v_rule.iso
                   and case b.kind
                         when 'number' then v_nat = b.value_from
                         when 'prefix' then v_nat like b.value_from || '%'
                         else length(v_nat) = length(b.value_from) and v_nat between b.value_from and b.value_to
                       end) then
    v_code := 'PHONE_BLOCKED';
  elsif p_new and v_rule.mobile_min is not null
        and (length(v_nat) < v_rule.mobile_min or length(v_nat) > v_rule.mobile_max) then
    v_code := 'PHONE_LENGTH';
  elsif p_new and v_rule.mobile_only and cardinality(v_rule.mobile_prefixes) > 0
        and not exists (select 1 from unnest(v_rule.mobile_prefixes) p where v_nat like p || '%') then
    v_code := 'PHONE_NOT_MOBILE';
  elsif p_new and v_rule.access = 'registration_closed' then
    v_code := 'PHONE_REGISTRATION_CLOSED';
  end if;
  if v_code is null then
    return '{}'::jsonb;
  end if;
  select c.name into v_name from public.countries c where upper(c.values->>'isoCode') = v_rule.iso limit 1;
  return jsonb_build_object('code', v_code, 'iso', v_rule.iso, 'country', coalesce(v_name, v_rule.iso),
                            'dial', v_rule.dial_code, 'min', v_rule.mobile_min, 'max', v_rule.mobile_max,
                            'starts', case when v_rule.iso = 'MY' then '01' else null end);
end;
$$;
revoke execute on function public.phone_rule_check(text, boolean) from public, anon, authenticated;

-- "<CODE>: <words>" for a phone_rule_check result.
create or replace function public.phone_rule_message(p jsonb)
returns text
language sql
immutable
set search_path = public
as $$
  select (p->>'code') || ': ' || case p->>'code'
    when 'PHONE_BLOCKED' then 'GET.ride isn''t available for numbers from ' || (p->>'country') || '.'
    when 'PHONE_LENGTH' then 'Mobile numbers from ' || (p->>'country') || ' are '
                             || case when p->>'min' = p->>'max' then p->>'min' else (p->>'min') || ' to ' || (p->>'max') end
                             || ' digits after ' || (p->>'dial') || '.'
    when 'PHONE_NOT_MOBILE' then 'This looks like a landline. Enter a mobile number from ' || (p->>'country')
                             || coalesce(' (starts with ' || (p->>'starts') || ')', '') || '.'
    when 'PHONE_REGISTRATION_CLOSED' then 'New accounts can''t be made with numbers from ' || (p->>'country') || ' right now.'
    when 'PHONE_DAILY_LIMIT' then 'Too many sign-ups right now. Please try again later.'
    else 'This number can''t be used to sign in.' end;
$$;

-- The phone screen: 0194's, with the country rules.
create or replace function public.profile_phone_lookup(p_phone text)
returns table (
  has_profile boolean,
  has_pin     boolean,
  is_deleted  boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ip   text := public.request_client_ip();
  v_wait integer := public.auth_rate_take('phone_lookup', v_ip, 20, interval '10 minutes');
  v_has  boolean;
  v_pin  boolean;
  v_del  boolean;
  v_rule jsonb;
begin
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait;
  end if;
  v_wait := public.auth_rate_take('phone_lookup_day', v_ip, 100, interval '1 day');
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait;
  end if;
  with digits as (
    select regexp_replace(coalesce(p_phone, ''), '\D', '', 'g') as d
  ),
  variants as (
    select array_remove(array['+' || d, d, '0' || d, ltrim(d, '0')], null) as v
    from digits
  ),
  match as (
    select p.pin_hash, p.profile_status
    from public.profiles p, variants
    where p.phone = any(variants.v)
      and p.deleted_at is null
    order by (lower(p.profile_status::text) = 'deleted'), p.created_at desc
    limit 1
  )
  select
    exists(select 1 from match),
    coalesce((select m.pin_hash is not null and m.pin_hash <> '' from match m), false),
    coalesce((select lower(m.profile_status::text) = 'deleted' from match m), false)
  into v_has, v_pin, v_del;
  v_rule := public.phone_rule_check(p_phone, not v_has);
  if v_rule ? 'code' then
    raise exception '%', public.phone_rule_message(v_rule);
  end if;
  return query select v_has, v_pin, v_del;
end;
$$;
revoke all on function public.profile_phone_lookup(text) from public;
grant execute on function public.profile_phone_lookup(text) to anon, authenticated;

-- Supabase Auth's Before User Created hook: 0287's, with the country rules.
create or replace function public.before_user_created_hook(event jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_user jsonb := coalesce(event -> 'user', '{}'::jsonb);
  v_rule jsonb;
begin
  -- Made by an admin (phone already confirmed), or not a phone sign-up.
  if nullif(v_user ->> 'phone_confirmed_at', '') is not null
     or nullif(v_user ->> 'email', '') is not null
     or nullif(v_user ->> 'phone', '') is null then
    return '{}'::jsonb;
  end if;
  v_rule := public.phone_rule_check(v_user ->> 'phone', true);
  if v_rule ? 'code' then
    return jsonb_build_object('error', jsonb_build_object('http_code', 403, 'message', public.phone_rule_message(v_rule)));
  end if;
  if public.registration_open(null) then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'REGISTRATION_CLOSED: There is no account for this number, and new sign-ups are closed.'));
end;
$$;
revoke all on function public.before_user_created_hook(jsonb) from public, anon, authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    execute 'grant execute on function public.before_user_created_hook(jsonb) to supabase_auth_admin';
  end if;
end $$;

-- Admins told when a country nears its daily code limit (Messaging or Regions admins).
create or replace function public.phone_limit_alert_recipients()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select distinct profile_id from public.admin_access
   where page in ('*', 'admin-settings-messaging', 'admin-settings-country-states-cities', 'admin-settings');
$$;
revoke execute on function public.phone_limit_alert_recipients() from public, anon, authenticated;

-- Codes queued to [p_iso]'s numbers today (Malaysian day).
create or replace function public.phone_codes_today(p_iso text)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int from public.sms_log
   where country_iso = p_iso and status = 'queued'
     and created_at >= (date_trunc('day', now() at time zone 'Asia/Kuala_Lumpur') at time zone 'Asia/Kuala_Lumpur');
$$;
revoke execute on function public.phone_codes_today(text) from public, anon, authenticated;

-- The SMS code hook: 0192's, with the country rules and the daily limit.
create or replace function public.send_sms_hook(event jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_phone text := public.sms_e164(event #>> '{user,phone}');
  v_user  uuid;
  v_code  text := event #>> '{sms,otp}';
  v_reason text;
  v_template text;
  v_outbox uuid;
  v_new   boolean;
  v_rule  jsonb;
  v_iso   text;
  v_limit integer;
  v_today integer;
  v_safe  boolean;
  r uuid;
begin
  begin
    v_user := (event #>> '{user,id}')::uuid;
  exception when others then
    v_user := null;
  end;
  -- One request at a time per number, so two at once can't both pass.
  perform pg_advisory_xact_lock(hashtextextended('sms_otp|' || coalesce(v_phone, ''), 149));

  -- A number with no account yet: checked for its length, mobile digits
  -- and closed registration too.
  v_new := not exists (select 1 from public.profiles p
                        where p.phone = any (array[v_phone, ltrim(coalesce(v_phone, ''), '+')]) and p.deleted_at is null);
  v_safe := public.phone_is_safe(v_phone);
  v_rule := public.phone_rule_check(v_phone, v_new);
  select (x.r).iso, (x.r).daily_code_limit into v_iso, v_limit from public.phone_country_rule(v_phone) x;
  if v_rule ? 'code' then
    insert into public.sms_log (phone, user_id, status, reason, country_iso)
    values (coalesce(v_phone, ''), v_user, 'blocked', lower(v_rule->>'code'), v_iso);
    return jsonb_build_object('error', jsonb_build_object('http_code', 403, 'message', public.phone_rule_message(v_rule)));
  end if;
  -- The country's daily limit stops new numbers; people with an account
  -- (Forgot PIN) still get theirs.
  if v_new and not v_safe and v_limit is not null then
    perform pg_advisory_xact_lock(hashtextextended('sms_otp_country|' || v_iso, 292));
    v_today := public.phone_codes_today(v_iso);
    if v_today >= v_limit then
      insert into public.sms_log (phone, user_id, status, reason, country_iso)
      values (coalesce(v_phone, ''), v_user, 'blocked', 'phone_daily_limit', v_iso);
      return jsonb_build_object('error', jsonb_build_object('http_code', 429,
        'message', public.phone_rule_message(jsonb_build_object('code', 'PHONE_DAILY_LIMIT'))));
    end if;
  end if;

  v_reason := public.sms_otp_refusal(v_phone);
  if v_reason is null and coalesce(v_code, '') = '' then
    v_reason := 'no_code';
  end if;
  if v_reason is not null then
    insert into public.sms_log (phone, user_id, status, reason, country_iso) values (coalesce(v_phone, ''), v_user, 'blocked', v_reason, v_iso);
    return public.sms_refusal_message(v_reason, public.sms_otp_wait_seconds(v_phone, v_reason));
  end if;

  select message_template into v_template from public.sms_settings where id = 1;
  insert into public.sms_outbox (to_phone, body, channel, created_by)
  values (v_phone, replace(coalesce(v_template, 'Your GET.ride code is {code}. Do not share it.'), '{code}', v_code), 'otp', null)
  returning id into v_outbox;
  insert into public.sms_log (phone, user_id, status, outbox_id, reason, country_iso)
  values (v_phone, v_user, 'queued', v_outbox, case when v_safe then 'safe_number' end, v_iso);
  if v_safe then
    update public.otp_safe_numbers set last_used_at = now() where phone = v_phone;
  end if;

  -- 80% of the day's limit: the admins hear once a day.
  if v_limit is not null and v_limit > 0 then
    v_today := public.phone_codes_today(v_iso);
    if v_today * 5 >= v_limit * 4
       and exists (select 1 from public.country_phone_rules c
                    where c.iso = v_iso and c.alerted_on is distinct from (now() at time zone 'Asia/Kuala_Lumpur')::date) then
      update public.country_phone_rules set alerted_on = (now() at time zone 'Asia/Kuala_Lumpur')::date where iso = v_iso;
      begin
        for r in select * from public.phone_limit_alert_recipients() loop
          perform public.approval_push_send(r,
            jsonb_build_object('title', 'Sign-in codes',
                               'body', v_today || ' of ' || v_limit || ' codes sent today to numbers from '
                                       || coalesce((select c.name from public.countries c where upper(c.values->>'isoCode') = v_iso limit 1), v_iso) || '.'),
            jsonb_build_object('type', 'phone_code_limit', 'iso', v_iso, 'for', 'admin'));
        end loop;
      exception when others then
        null;  -- an alert never stops a code
      end;
    end if;
  end if;
  return '{}'::jsonb;
exception when others then
  begin
    insert into public.sms_log (phone, user_id, status, reason)
    values (coalesce(v_phone, ''), v_user, 'failed', left(sqlerrm, 200));
  exception when others then
    null;
  end;
  return public.sms_refusal_message('error');
end;
$function$;
revoke execute on function public.send_sms_hook(jsonb) from public, anon, authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    execute 'grant execute on function public.send_sms_hook(jsonb) to supabase_auth_admin';
  end if;
end $$;

-- PIN sign-in: 0192's, refusing a blocked country or number.
create or replace function public.pin_check(p_phone text, p_pin text, p_ip text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_digits   text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  v_row      record;
  v_matched  boolean := false;
  v_attempts integer;
  -- Keyed as in 0137: no address (SQL, the service role) is not limited
  -- here; pin-login always passes one. The per-account lockout below holds
  -- either way.
  v_wait     integer := public.auth_rate_take('pin_check', p_ip, 30, interval '10 minutes');
begin
  if v_wait > 0 then
    raise exception 'RATE_LIMITED:%', v_wait;
  end if;
  if v_digits = '' then
    return null;
  end if;
  -- A country or number blocked from GET.ride (0292): no sign-in at all.
  if public.phone_rule_check('+' || v_digits, false)->>'code' = 'PHONE_BLOCKED' then
    raise exception '%', public.phone_rule_message(public.phone_rule_check('+' || v_digits, false));
  end if;

  select p.id, p.pin_hash, p.pin_failed_attempts, p.pin_locked_until
    into v_row
    from public.profiles p
   where p.phone = any (array_remove(array[
           '+' || v_digits,
           v_digits,
           '0' || v_digits,
           ltrim(v_digits, '0')
         ], null))
   limit 1
     for update;

  if v_row.id is null then
    return null;
  end if;

  if v_row.pin_locked_until is not null and v_row.pin_locked_until > now() then
    raise exception 'PIN_LOCKED:%',
      ceil(extract(epoch from (v_row.pin_locked_until - now())))::integer;
  end if;

  if v_row.pin_hash is not null and v_row.pin_hash <> '' then
    v_matched := v_row.pin_hash = crypt(p_pin, v_row.pin_hash);
  end if;

  if v_matched then
    update public.profiles
       set pin_failed_attempts = 0,
           pin_locked_until    = null
     where id = v_row.id;
    return v_row.id;
  end if;

  v_attempts := coalesce(v_row.pin_failed_attempts, 0) + 1;
  if v_attempts >= (public.pin_policy()->>'maxAttempts')::int then
    update public.profiles
       set pin_failed_attempts = 0,
           pin_locked_until    = now() + make_interval(mins => (public.pin_policy()->>'lockMinutes')::int)
     where id = v_row.id;
  else
    update public.profiles
       set pin_failed_attempts = v_attempts
     where id = v_row.id;
  end if;
  return null;
end;
$function$;


-- Signed in already: a blocked country or number is signed out at the
-- app's next check (0180's, with the rule first).
create or replace function public.session_is_current()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_sid uuid := public.current_session_id();
  a public.active_sessions;
  v_created timestamptz;
  v_phone text;
begin
  if v_uid is null then
    return true;
  end if;
  -- Only looked up while a country or number is blocked at all.
  if exists (select 1 from public.country_phone_rules where access = 'blocked')
     or exists (select 1 from public.phone_number_blocks) then
    select phone into v_phone from public.profiles where id = v_uid;
    if v_phone is not null and public.phone_rule_check(v_phone, false)->>'code' = 'PHONE_BLOCKED' then
      return false;
    end if;
  end if;
  select * into a from public.active_sessions where user_id = v_uid;
  if not found or a.session_id = v_sid then
    return true;
  end if;
  if v_sid is null then
    return false;
  end if;
  select created_at into v_created from auth.sessions where id = v_sid;
  return v_created is not null and v_created > a.claimed_at and v_created > now() - interval '2 minutes';
end;
$$;
revoke execute on function public.session_is_current() from public, anon;
grant execute on function public.session_is_current() to authenticated;

-- ---- 5. Admin ---------------------------------------------------------------------------------------
-- Saves a country's rule: p { min, max, prefixes[], mobileOnly, access, dailyLimit }.
create or replace function public.admin_country_phone_rule_set(p_iso text, p jsonb)
returns public.country_phone_rules
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.country_phone_rules;
  v_pre text[];
begin
  if not public.caller_admin_can_write('rpc:admin_country_phone_rule_set') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select array_agg(distinct x order by x) into v_pre
    from jsonb_array_elements_text(coalesce(p->'prefixes', '[]'::jsonb)) x where x ~ '^[0-9]{1,6}$';
  update public.country_phone_rules c set
    mobile_min = case when p ? 'min' then nullif(p->>'min', '')::int else c.mobile_min end,
    mobile_max = case when p ? 'max' then nullif(p->>'max', '')::int else c.mobile_max end,
    mobile_prefixes = case when p ? 'prefixes' then coalesce(v_pre, '{}') else c.mobile_prefixes end,
    mobile_only = coalesce((p->>'mobileOnly')::boolean, c.mobile_only),
    access = coalesce(p->>'access', c.access),
    daily_code_limit = case when p ? 'dailyLimit' then nullif(p->>'dailyLimit', '')::int else c.daily_code_limit end,
    updated_at = now(), updated_by = auth.uid()
   where c.iso = upper(p_iso)
  returning * into v;
  if v.iso is null then
    raise exception 'COUNTRY_PHONE_RULE_MISSING' using hint = 'No phone data for this country code.';
  end if;
  return v;
end;
$$;
revoke execute on function public.admin_country_phone_rule_set(text, jsonb) from public, anon;
grant execute on function public.admin_country_phone_rule_set(text, jsonb) to authenticated;

-- Before blocking: how many accounts use the country's numbers, and today's
-- codes to them.
create or replace function public.admin_country_phone_stats(p_iso text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_dial text;
  v_people integer;
begin
  if not public.caller_admin_can_write('rpc:admin_country_phone_rule_set') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  select dial_code into v_dial from public.country_phone_rules where iso = upper(p_iso);
  select count(*) into v_people from public.profiles pr
   where pr.deleted_at is null and pr.phone is not null
     and (select (x.r).iso from public.phone_country_rule(pr.phone) x) = upper(p_iso);
  return jsonb_build_object('people', coalesce(v_people, 0), 'codesToday', public.phone_codes_today(upper(p_iso)));
end;
$$;
revoke execute on function public.admin_country_phone_stats(text) from public, anon;
grant execute on function public.admin_country_phone_stats(text) to authenticated;

create or replace function public.admin_phone_block_add(p_iso text, p_kind text, p_from text, p_to text, p_note text)
returns public.phone_number_blocks
language plpgsql
security definer
set search_path = public
as $$
declare
  v public.phone_number_blocks;
begin
  if not public.caller_admin_can_write('rpc:admin_phone_block_add') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  insert into public.phone_number_blocks (iso, kind, value_from, value_to, note, created_by)
  values (upper(p_iso), p_kind, ltrim(regexp_replace(p_from, '\D', '', 'g'), '0'),
          case when p_kind = 'range' then ltrim(regexp_replace(p_to, '\D', '', 'g'), '0') end,
          nullif(btrim(p_note), ''), auth.uid())
  returning * into v;
  return v;
end;
$$;
revoke execute on function public.admin_phone_block_add(text, text, text, text, text) from public, anon;
grant execute on function public.admin_phone_block_add(text, text, text, text, text) to authenticated;

create or replace function public.admin_phone_block_remove(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.caller_admin_can_write('rpc:admin_phone_block_add') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  delete from public.phone_number_blocks where id = p_id;
end;
$$;
revoke execute on function public.admin_phone_block_remove(uuid) from public, anon;
grant execute on function public.admin_phone_block_remove(uuid) to authenticated;

-- Adds ([p_add] true) or removes a test or staff number.
create or replace function public.admin_otp_safe_set(p_phone text, p_add boolean, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v text := '+' || regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if not public.caller_admin_can_write('rpc:admin_otp_safe_set') then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_add then
    insert into public.otp_safe_numbers (phone, note, created_by) values (v, nullif(btrim(p_note), ''), auth.uid())
    on conflict (phone) do update set note = excluded.note;
  else
    delete from public.otp_safe_numbers where phone = v;
  end if;
end;
$$;
revoke execute on function public.admin_otp_safe_set(text, boolean, text) from public, anon;
grant execute on function public.admin_otp_safe_set(text, boolean, text) to authenticated;

insert into public.admin_table_pages (target, page) values
  ('rpc:admin_country_phone_rule_set', 'admin-settings-country-states-cities'),
  ('rpc:admin_phone_block_add',        'admin-settings-country-states-cities'),
  ('rpc:admin_otp_safe_set',           'admin-settings-messaging')
on conflict do nothing;

notify pgrst, 'reload schema';

insert into supabase_migrations.schema_migrations (version, name)
values ('20261025140000', '0292_country_phone_rules')
on conflict do nothing;
