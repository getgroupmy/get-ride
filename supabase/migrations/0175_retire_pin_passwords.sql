-- ============================================================================
-- 0175: retire the PIN-derived Auth passwords (phase 2 of 0172)
--
-- Builds before 1.4.5 signed in by sending Auth the password
-- 'teksi-pin-v1-' || pin: a million guesses per phone number at Auth's
-- password grant, which has no per-account lockout. 1.4.5 signs in through
-- the pin-login function instead (bcrypt check, rate limit and lockout in
-- the database), and every sign-in there writes a fresh random password.
-- With App Version's minimum at 1.4.5, no supported build needs the old
-- password, so every phone account's password is replaced here by a random
-- one nobody knows. Accounts that already have a random one simply get
-- another.
--
--   * Signed-in phones stay signed in: sessions and refresh tokens are not
--     touched.
--   * PIN sign-in keeps working through pin-login, which sets its own
--     password each time; the SMS code works as before.
--   * Accounts with an email address are left alone: their password may be
--     a real one somebody chose (none exist today).
--
-- Run only once App Version's minimum version is 1.4.5 or later: a build
-- older than that would fail PIN sign-in afterwards (the SMS code still
-- works for it).
-- ============================================================================

update auth.users
   set encrypted_password = extensions.crypt(
         encode(extensions.gen_random_bytes(32), 'base64'),
         extensions.gen_salt('bf')
       ),
       updated_at = now()
 where coalesce(phone, '') <> ''
   and coalesce(email, '') = '';
