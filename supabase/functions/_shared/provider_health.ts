/**
 * The pure half of the `provider-health` function (migration 0440): which
 * Admin → API Keys providers are monitored, the self-hosted server to ping for
 * each, and what counts as "down".
 *
 * A provider is monitored when its api_providers entry has `monitor === true`
 * (the admin's "Monitor this server" switch). Its server address is read out of
 * the first usable key: a face / eKYC key ("https://host:secret",
 * _shared/face_server.ts), a Umami key ("https://host user:pass",
 * _shared/nas_stats.ts), or a bare "https://host" saved as the key (a custom
 * OSRM / Overpass / Nominatim server). A provider with no https address in any
 * key has no server to ping and is left out.
 *
 * The face match server (face_match) keeps its own watcher (0347), so it is
 * never monitored here (BUILTIN_WATCHED).
 *
 *     deno test supabase/functions/_shared/provider_health_test.ts
 */

import { parseFaceServer } from "./face_server.ts";
import { parseUmamiKey } from "./nas_stats.ts";

/** How long to wait for a server's /health before calling it down. */
export const PROVIDER_HEALTH_TIMEOUT_MS = 10000;

/** Providers with their own dedicated offline watcher: not monitored here. */
export const BUILTIN_WATCHED = new Set<string>(["face_match"]);

export interface MonitorTarget {
  /** The provider id (api_providers). */
  id: string;
  /** The provider's name, for the push. */
  label: string;
  /** https base to ping, no trailing slash. */
  url: string;
  /** x-api-key to send, when the key carried one (a face / eKYC server key). */
  apiKey?: string;
}

interface KeyEntry {
  value?: unknown;
  disabled?: unknown;
}
interface SvcEntry {
  keys?: unknown;
}
interface ProvEntry {
  id?: unknown;
  name?: unknown;
  monitor?: unknown;
  services?: unknown;
}

/** A pingable https base (+ optional key) read from a stored key value, or null. */
export function serverFromKeyValue(value: string): { url: string; apiKey?: string } | null {
  // Umami first: its "url user:pass" / "url token" form (a space between the
  // two) also parses as a face key ("url secret"), but its credentials are not
  // an x-api-key. A face / eKYC key uses the colon form ("url:secret", no
  // space), so it never matches the Umami regex.
  const umami = parseUmamiKey(value);
  if (umami) return { url: umami.url };
  const face = parseFaceServer(value);
  if (face) return { url: face.url, apiKey: face.secret };
  // A bare https address saved as the key (a custom self-hosted server).
  const m = /^(https:\/\/[^\s:/]+(?::\d{1,5})?)(?:\/\S*)?$/.exec((value ?? "").trim());
  return m ? { url: m[1] } : null;
}

/**
 * The monitored providers (monitor === true) that expose a server to ping, in
 * list order; the first usable key of the first service that has one wins.
 * Built-in-watched providers are skipped.
 */
export function monitorTargets(apiProviders: unknown): MonitorTarget[] {
  const list = Array.isArray(apiProviders)
    ? apiProviders
    : (apiProviders as { providers?: unknown } | null)?.providers;
  if (!Array.isArray(list)) return [];
  const out: MonitorTarget[] = [];
  for (const p of list as ProvEntry[]) {
    const id = typeof p?.id === "string" ? p.id : "";
    if (!id || p?.monitor !== true || BUILTIN_WATCHED.has(id)) continue;
    const label = typeof p?.name === "string" && p.name.trim() ? p.name.trim() : id;
    let found: { url: string; apiKey?: string } | null = null;
    for (const s of (Array.isArray(p?.services) ? p.services : []) as SvcEntry[]) {
      for (const k of (Array.isArray(s?.keys) ? s.keys : []) as KeyEntry[]) {
        if (k?.disabled === true || typeof k?.value !== "string") continue;
        found = serverFromKeyValue(k.value);
        if (found) break;
      }
      if (found) break;
    }
    if (found) out.push({ id, label, url: found.url, apiKey: found.apiKey });
  }
  return out;
}

/**
 * down iff the server could not be reached (a network error / timeout, or a
 * 5xx); any answer — a 401 or a 404 included — means it is up. A wrong key is
 * the Test button's job, not an outage.
 */
export function healthState(r: { status?: number; failed?: boolean }): "ok" | "down" {
  if (r.failed) return "down";
  const s = r.status ?? 0;
  return s === 0 || s >= 500 ? "down" : "ok";
}
