/**
 * Own maps on the office NAS (migration 0319): the pure half of the
 * `nas-maps` function, which the NAS's agent (deploy/nas-maps/agent) calls.
 * The NAS only ever calls out, with the key it got for its pairing code:
 *
 *   pair       { code, device_id, label?, model?, version? }  -> { key, server, label }
 *   heartbeat  { status, detail?, model?, version?, mapsUrl?, tilesUrl?, secret? }
 *                                                             -> { server, label, settings, pollAfter }
 *
 * heartbeat sends the key in the x-nas-key header. status is "ok",
 * "degraded", "refreshing" or "down"; detail is what the agent checked
 * (OSRM, Photon, the tiles, the weekly refresh). mapsUrl and tilesUrl are
 * the NAS's Cloudflare Tunnel addresses, and secret the header value the
 * geo function must send to mapsUrl (kept for the geo function only).
 * Nothing here touches the network; see nas_maps_test.ts.
 */

/** How often the agent checks in. */
export const HEARTBEAT_SECONDS = 60;

export interface NasMapsDeps {
  /** A database function, called with the service role. Throws its error. */
  rpc(name: string, args: Record<string, unknown>): Promise<unknown>;
}

export interface Reply {
  status: number;
  body: Record<string, unknown>;
}

const str = (v: unknown, max = 200): string | null =>
  typeof v === "string" && v.trim() !== "" ? v.trim().slice(0, max) : null;

const STATUSES = new Set(["ok", "degraded", "refreshing", "down"]);

/** A database error's code word (NAS_KEY_INVALID …), when it is one of ours. */
function errorWord(e: unknown): string | null {
  const m = (e as { message?: unknown } | null)?.message;
  return typeof m === "string" && /^NAS_[A-Z_]+$/.test(m) ? m : null;
}

/** The detail the agent sent, as an object of at most 20 kB, without anything named like a secret. */
export function cleanDetail(v: unknown): Record<string, unknown> {
  if (!v || typeof v !== "object" || Array.isArray(v)) return {};
  const strip = (x: unknown, depth: number): unknown => {
    if (depth > 4) return null;
    if (Array.isArray(x)) return x.slice(0, 50).map((y) => strip(y, depth + 1));
    if (x && typeof x === "object") {
      const out: Record<string, unknown> = {};
      for (const [k, y] of Object.entries(x as Record<string, unknown>)) {
        if (/secret|key|token|password/i.test(k)) continue;
        out[k.slice(0, 40)] = strip(y, depth + 1);
      }
      return out;
    }
    return typeof x === "string" ? x.slice(0, 300) : x;
  };
  const d = strip(v, 0) as Record<string, unknown>;
  return JSON.stringify(d).length > 20000 ? { error: "detail too large" } : d;
}

export async function handleNasMaps(input: unknown, key: string | null, deps: NasMapsDeps): Promise<Reply> {
  const body = (input && typeof input === "object" ? input : {}) as Record<string, unknown>;
  const action = body.action;

  if (action === "pair") {
    const code = str(body.code, 20);
    const device = str(body.device_id);
    if (!code || !device) return { status: 400, body: { error: "bad_request", hint: "Send the code and a device id." } };
    const r = (await deps.rpc("nas_maps_pair", {
      p_code: code,
      p_device_id: device,
      p_label: str(body.label, 80),
      p_model: str(body.model, 120),
      p_app_version: str(body.version, 40),
    })) as Record<string, unknown> | null;
    if (!r || typeof r.error === "string") {
      return { status: r?.error === "NAS_PAIR_BUSY" ? 429 : 400, body: r ?? { error: "NAS_PAIR_CODE" } };
    }
    return { status: 200, body: r };
  }

  if (action !== "heartbeat") return { status: 400, body: { error: "bad_request", hint: "Unknown action." } };
  if (!key || key.length < 32) {
    return { status: 401, body: { error: "NAS_KEY_INVALID", hint: "Send the NAS key in x-nas-key." } };
  }
  const status = typeof body.status === "string" && STATUSES.has(body.status) ? body.status : "degraded";
  try {
    const r = (await deps.rpc("nas_maps_heartbeat", {
      p_key: key,
      p_status: status,
      p_detail: cleanDetail(body.detail),
      p_model: str(body.model, 120),
      p_app_version: str(body.version, 40),
      p_maps_url: str(body.mapsUrl, 200),
      p_tiles_url: str(body.tilesUrl, 200),
      p_secret: str(body.secret, 200),
    })) as Record<string, unknown>;
    return { status: 200, body: { ...r, pollAfter: HEARTBEAT_SECONDS } };
  } catch (e) {
    if (errorWord(e) === "NAS_KEY_INVALID") {
      return {
        status: 401,
        body: { error: "NAS_KEY_INVALID", hint: "Connect the NAS again from Admin -> Settings -> Office NAS -> Maps." },
      };
    }
    throw e;
  }
}
