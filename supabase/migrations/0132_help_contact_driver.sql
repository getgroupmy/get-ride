-- 0132: the help assistant's "How do I contact my driver?" answer, brought up
-- to date with in-app ride chat (0129) and in-app ride calls (0131).
--
-- 0130 seeds the new text on a fresh database; this updates a database that
-- was already seeded. An article an admin has edited is left alone: only the
-- row still carrying the original seeded answer changes.
update public.help_articles
   set answer = 'Use Call or Message on the ride screen once a driver has accepted. Call rings your driver in the app over mobile data or Wi-Fi, without showing either phone number; press and hold Call for an ordinary phone call when their number is available. Message opens the in-app chat for this ride.',
       keywords = array['call', 'message', 'chat', 'contact', 'driver', 'sms', 'hubungi', 'pemandu', 'telefon', 'voice call', 'in-app call']::text[]
 where id = '68656c70-0000-4000-8000-000000000024'
   and answer = 'Use Call or Message on the ride screen once a driver has accepted. Call opens your phone''s dialler and Message opens your SMS app with the driver''s number. There is no separate in-app chat with the driver.';
