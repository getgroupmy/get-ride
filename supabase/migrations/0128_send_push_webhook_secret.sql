-- ============================================================================
-- send-push: the database webhook proves itself with a Vault secret
-- ----------------------------------------------------------------------------
-- send-push was public: deployed --no-verify-jwt and checking no caller, so
-- anyone with the project URL could push to every device. It now sends only
-- for the service-role key, a signed-in admin, or this webhook.
--
-- The webhook (`send_push_webhook`, 0067 in the 0097 baseline) attached the
-- Vault `service_role_key` as a bearer when that secret existed, and posted
-- without it otherwise. Now it sends the Vault secret `push_webhook_secret`
-- in an `x-push-secret` header, and no-ops without it. send-push asks
-- `push_webhook_secret_ok()` (service role only) whether the header matches,
-- so the secret exists in one place and nothing has to be copied into the
-- function's secrets.
--
-- The secret is generated here when missing. To rotate it (SQL editor):
--   select vault.update_secret(id, encode(extensions.gen_random_bytes(32), 'hex'))
--     from vault.secrets where name = 'push_webhook_secret';
--
-- Safe to re-run.
-- ============================================================================

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'push_webhook_secret') then
    perform vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'hex'),
      'push_webhook_secret',
      'x-push-secret the database webhook sends to the send-push edge function'
    );
  end if;
end
$$;

create or replace function public.push_webhook_secret_ok(p_secret text)
returns boolean
language sql
stable
security definer
set search_path = public, vault
as $$
  select coalesce(p_secret, '') <> '' and exists (
    select 1 from vault.decrypted_secrets
     where name = 'push_webhook_secret' and decrypted_secret = p_secret
  );
$$;

revoke execute on function public.push_webhook_secret_ok(text) from public, anon, authenticated;
grant execute on function public.push_webhook_secret_ok(text) to service_role;

create or replace function public.send_push_webhook(p_body jsonb)
returns void
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_url    text;
  v_secret text;
begin
  -- Pull config from Vault; bail out gracefully if unreadable.
  begin
    select decrypted_secret into v_url
      from vault.decrypted_secrets where name = 'project_url' limit 1;
    select decrypted_secret into v_secret
      from vault.decrypted_secrets where name = 'push_webhook_secret' limit 1;
  exception when others then
    return;
  end;

  -- send-push refuses a webhook call without the secret, so don't make one.
  if v_url is null or v_secret is null then
    return;
  end if;

  perform net.http_post(
    url     := v_url || '/functions/v1/send-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-push-secret', v_secret
    ),
    body    := p_body
  );
exception when others then
  -- Never let a notification failure block the parent write.
  null;
end;
$$;

revoke execute on function public.send_push_webhook(jsonb) from public, anon, authenticated;
