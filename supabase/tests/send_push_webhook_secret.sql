-- ============================================================================
-- Regression test for migration 0127: the send-push webhook secret exists,
-- only the service role can check it, and the check is exact.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/send_push_webhook_secret.sql
--
-- Read-only. A failed assertion raises an exception.
-- ============================================================================
do $$
declare
  v_secret text;
  r record;
begin
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'push_webhook_secret';
  if coalesce(length(v_secret), 0) < 32 then
    raise exception 'push_webhook_secret missing or short';
  end if;

  if not public.push_webhook_secret_ok(v_secret) then
    raise exception 'the secret itself should pass';
  end if;
  if public.push_webhook_secret_ok(v_secret || 'x')
     or public.push_webhook_secret_ok(left(v_secret, 10))
     or public.push_webhook_secret_ok('')
     or public.push_webhook_secret_ok(null) then
    raise exception 'anything but the exact secret should fail';
  end if;

  for r in
    select * from (values
      ('public.push_webhook_secret_ok(text)', 'anon',          false),
      ('public.push_webhook_secret_ok(text)', 'authenticated', false),
      ('public.push_webhook_secret_ok(text)', 'service_role',  true),
      ('public.send_push_webhook(jsonb)',     'anon',          false),
      ('public.send_push_webhook(jsonb)',     'authenticated', false)
    ) as t(fn, role, expected)
  loop
    if has_function_privilege(r.role, r.fn, 'execute') is distinct from r.expected then
      raise exception '% EXECUTE for % should be %', r.fn, r.role, r.expected;
    end if;
  end loop;
end
$$;

select 'send_push_webhook_secret: all passed';
