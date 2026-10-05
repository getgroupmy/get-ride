-- ============================================================================
-- Ride-request push webhook
-- ----------------------------------------------------------------------------
-- When a passenger creates a new `open` ride request, automatically notify the
-- partner (driver) audience by calling the `send-push` edge function from the
-- database via pg_net (async HTTP).
--
-- Config is read from Supabase Vault so no secrets live in the schema:
--   * project_url        — your project URL, e.g. https://xxxx.supabase.co
--   * service_role_key   — the service-role key (allows calling the function)
--
-- Set them once (SQL editor), then re-run is safe:
--   select vault.create_secret('https://YOURREF.supabase.co', 'project_url');
--   select vault.create_secret('YOUR_SERVICE_ROLE_KEY',       'service_role_key');
--
-- If either secret is missing the trigger no-ops quietly (never blocks inserts).
-- Safe to re-run.
-- ============================================================================

create extension if not exists pg_net with schema extensions;

create or replace function public.notify_partners_on_ride_request()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, vault
as $$
declare
  v_url    text;
  v_key    text;
  v_pickup text;
  v_body   text;
begin
  -- Only fire for brand-new open requests.
  if new.status is distinct from 'open' then
    return new;
  end if;

  -- Pull config from Vault; bail out gracefully if not configured.
  begin
    select decrypted_secret into v_url
      from vault.decrypted_secrets where name = 'project_url' limit 1;
    select decrypted_secret into v_key
      from vault.decrypted_secrets where name = 'service_role_key' limit 1;
  exception when others then
    return new;
  end;

  if v_url is null or v_key is null then
    return new;
  end if;

  v_pickup := coalesce(nullif(new.pickup_name, ''), nullif(new.pickup_address, ''), 'a nearby location');
  v_body   := 'Pickup at ' || v_pickup ||
              case when new.fare is not null
                   then ' • ' || coalesce(new.currency, '') || ' ' || new.fare::text
                   else '' end;

  perform net.http_post(
    url     := v_url || '/functions/v1/send-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_key
    ),
    body    := jsonb_build_object(
      'title', 'New ride request',
      'body', v_body,
      'audience', 'partners',
      'data', jsonb_build_object(
        'type', 'ride_request',
        'ride_request_id', new.id
      )
    )
  );

  return new;
exception when others then
  -- Never let a notification failure block the ride request insert.
  return new;
end;
$$;

do $$
begin
  drop trigger if exists trg_ride_request_push on public.ride_requests;
  create trigger trg_ride_request_push
    after insert on public.ride_requests
    for each row execute function public.notify_partners_on_ride_request();
end$$;
