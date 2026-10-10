-- ============================================================================
-- 0138: the PIN functions can find pgcrypto again
--
-- set_login_pin and verify_pin_for_login hash and check PINs with pgcrypto's
-- crypt() / gen_salt(). On Supabase pgcrypto lives in the `extensions`
-- schema, but both functions ran with `search_path = public`, so every call
-- that reached the hash failed with "function crypt(…) does not exist":
-- choosing or changing a PIN, the change-PIN check, and the sign-in check that
-- repairs a drifted password. (hash_profile_pin already had the fix, 0097.)
-- ============================================================================

alter function public.set_login_pin(text, text) set search_path = public, extensions;
alter function public.verify_pin_for_login(text, text) set search_path = public, extensions;

notify pgrst, 'reload schema';
