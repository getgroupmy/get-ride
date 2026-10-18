/**
 * proxy.getride.my: a test session's internet, through a gateway phone.
 *
 * ## Why this exists
 *
 * A live, real-world test of the app runs in a Claude Code cloud session
 * (or a CI job) in a data centre. Some things only behave the same from a
 * real Malaysian SIM: carrier-side pages, geo-fenced APIs, the networks our
 * riders are actually on. The GET.ride Gateway phone already sits on such
 * a SIM, so it can carry the session's requests too.
 *
 * The phone cannot be reached from outside (mobile carriers give it no
 * public address), so it dials in: the gateway app keeps a WebSocket open
 * to this worker, and this worker hands it each request a session makes.
 * The phone performs the request over its mobile data and streams the
 * answer back; the worker returns it to the session as an ordinary HTTP
 * response. To the session it is an HTTP fetch-through:
 *
 *     curl -H "Authorization: Bearer $GETRIDE_SESSION_KEY" \
 *          https://proxy.getride.my/https://example.com/path?q=1
 *
 * ## Who may
 *
 * Two keys, both checked against the backend (migration 0226):
 *
 *   - a session key (Admin -> SMS / WhatsApp -> Session access, with
 *     "Use a gateway phone's internet" ticked) names the phone it goes
 *     through: `session_key_proxy_check`;
 *   - the phone itself connects with its device key (pairing, 0190):
 *     `gateway_key_check` says which phone it is.
 *
 * A session key's answer is kept for 30 s, so a burst of requests is one
 * lookup; removing the key in Admin takes effect within that.
 *
 * ## The relay
 *
 * One Durable Object per gateway phone (`PhoneRelay`, named by the phone's
 * device row id) holds the phone's socket and the requests in flight. The
 * wire format is JSON text frames, chunked because a Workers WebSocket
 * message may not exceed 1 MiB:
 *
 *   relay -> phone   {id, method, url, headers: [[name, value], ...]}
 *                    {id, chunk: <base64>} ...       the request body
 *                    {id, end: true}
 *   phone -> relay   {id, status, headers: [[name, value], ...]}
 *                    {id, chunk: <base64>} ...       the response body
 *                    {id, end: true}
 *               or   {id, error: "why"}
 *
 * The phone sends "ping" now and then; the relay answers "pong" without
 * waking the object (WebSocket hibernation).
 *
 * ## What it does not do
 *
 * It is not a CONNECT proxy: a cloud session's outbound traffic goes
 * through the session's own agent proxy, whose policy must allow
 * proxy.getride.my (docs/session-access.md). It never follows redirects
 * (the session sees the 3xx and decides), and it strips the session key
 * and the hop-by-hop headers before anything reaches the phone.
 *
 * ## Deploying it
 *
 *     npx wrangler deploy            # from this directory
 *
 * `.github/workflows/cloudflare-worker.yml` does that on every push to
 * main that touches it. The route `proxy.getride.my/*` is more specific
 * than the subdomain proxy's `*.getride.my/*`, so it wins for this host;
 * the proxied wildcard DNS record that worker needs serves this one too.
 */

export default {
  /**
   * @param {Request} request
   * @param {Record<string, any>} env
   */
  fetch(request, env) {
    return handle(request, env, {
      rpc: (name, params) => rpc(env, name, params),
      relay: (deviceId, req) => env.RELAY.get(env.RELAY.idFromName(deviceId)).fetch(req),
    });
  },
};

/** How long a session key's answer is kept before the backend is asked again. */
export const SESSION_CACHE_MS = 30_000;

/** The most a request body may be. */
export const MAX_REQUEST_BODY = 20 * 1024 * 1024;

/** Raw bytes per chunk frame: base64 of it stays well under the 1 MiB frame limit. */
export const CHUNK_BYTES = 192 * 1024;

/** How long the phone has to start answering, and between chunks. */
export const PHONE_TIMEOUT_MS = 60_000;

/** The path the phone connects on. */
export const PHONE_PATH = "/phone";

/** A WebSocket's readyState while it can send (the standard OPEN). */
export const WS_OPEN = 1;

/**
 * The absolute URL a session asked for, from the path it called:
 * `/https://example.com/a?b=1` -> `https://example.com/a?b=1`. A path that
 * is not an http(s) URL is null. A client that collapsed `//` to `/` is
 * read the same.
 *
 * @param {string} pathAndQuery the request URL's pathname plus search
 * @returns {string | null}
 */
export function targetFrom(pathAndQuery) {
  const m = /^\/(https?):\/{1,2}(.+)$/i.exec(pathAndQuery);
  if (!m) return null;
  const url = `${m[1].toLowerCase()}://${m[2]}`;
  try {
    const u = new URL(url);
    if (!u.hostname || u.hostname.endsWith(".")) return null;
    return u.toString();
  } catch {
    return null;
  }
}

/**
 * The key a request carries: `Authorization: Bearer <key>` (curl's -H),
 * or `X-Session-Key: <key>` for clients that keep Authorization for the
 * target. Null when there is none.
 *
 * @param {Headers} headers
 * @returns {string | null}
 */
export function bearerFrom(headers) {
  const auth = headers.get("authorization") ?? "";
  const m = /^\s*Bearer\s+(\S+)\s*$/i.exec(auth);
  if (m) return m[1];
  const x = (headers.get("x-session-key") ?? "").trim();
  return x || null;
}

/** Headers that belong to one hop and must not be forwarded either way. */
const HOP_BY_HOP = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "proxy-connection",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

/**
 * Request headers that are the session's, the edge's or the relay's, never
 * the target's: the session key, where the session came from, and what
 * Cloudflare added. `accept-encoding` goes too: the phone negotiates
 * compression itself and hands back plain bytes, so a session asking for
 * gzip must not be told it got it.
 */
const NOT_FORWARDED = new Set([
  ...HOP_BY_HOP,
  "authorization",
  "x-session-key",
  "host",
  "content-length",
  "accept-encoding",
  "expect",
  "x-forwarded-for",
  "x-forwarded-proto",
  "x-forwarded-host",
  "x-real-ip",
  "true-client-ip",
  "cdn-loop",
]);

/**
 * The request headers the phone sends on, as [name, value] pairs.
 *
 * @param {Headers} headers
 * @returns {[string, string][]}
 */
export function forwardHeaders(headers) {
  const out = [];
  for (const [name, value] of headers) {
    const n = name.toLowerCase();
    if (NOT_FORWARDED.has(n) || n.startsWith("cf-") || n.startsWith("x-relay-")) continue;
    out.push([n, value]);
  }
  return out;
}

/**
 * The response headers the session gets: the phone's, minus hop-by-hop
 * ones and the framing that no longer applies (the body is re-streamed,
 * decompressed), plus which phone answered.
 *
 * @param {unknown} pairs the phone's [name, value] list
 * @param {string} phoneLabel
 * @returns {Headers}
 */
export function responseHeaders(pairs, phoneLabel) {
  const h = new Headers();
  if (Array.isArray(pairs)) {
    for (const p of pairs) {
      if (!Array.isArray(p) || p.length !== 2) continue;
      const n = String(p[0]).toLowerCase();
      if (HOP_BY_HOP.has(n) || n === "content-length" || n === "content-encoding") continue;
      try {
        h.append(n, String(p[1]));
      } catch {
        // A name or value the platform refuses: dropped rather than failing the response.
      }
    }
  }
  h.set("x-relay-phone", phoneLabel || "gateway");
  h.set("cache-control", "no-store");
  return h;
}

/** Statuses that carry no body. */
export const NO_BODY = new Set([101, 204, 205, 304]);

/**
 * Bytes -> base64, in chunks small enough for one frame each.
 *
 * @param {Uint8Array} bytes
 * @returns {string[]}
 */
export function toChunks(bytes) {
  const out = [];
  for (let i = 0; i < bytes.length; i += CHUNK_BYTES) {
    out.push(toBase64(bytes.subarray(i, i + CHUNK_BYTES)));
  }
  return out;
}

/** @param {Uint8Array} bytes */
export function toBase64(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  }
  return btoa(s);
}

/** @param {string} b64 */
export function fromBase64(b64) {
  const s = atob(b64);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

/**
 * A JSON answer in the shape every refusal here has.
 *
 * @param {number} status
 * @param {string} error
 * @param {string} hint
 */
export function refuse(status, error, hint) {
  return Response.json({ error, hint }, { status, headers: { "cache-control": "no-store" } });
}

/**
 * Calls a backend function with the project's public anon key, as the
 * phone and the session do. A PostgREST error comes back as
 * `{ error, hint }` rather than thrown, so the caller can say why.
 *
 * @param {Record<string, any>} env
 * @param {string} name
 * @param {Record<string, unknown>} params
 */
export async function rpc(env, name, params) {
  const base = String(env.SUPABASE_URL ?? "").replace(/\/$/, "");
  const key = String(env.SUPABASE_ANON_KEY ?? "");
  const res = await fetch(`${base}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: key,
      authorization: `Bearer ${key}`,
      "content-type": "application/json",
      accept: "application/json",
    },
    body: JSON.stringify(params),
  });
  const body = await res.json().catch(() => null);
  if (!res.ok) {
    return {
      error: String(body?.message ?? body?.error ?? `HTTP ${res.status}`),
      hint: String(body?.hint ?? ""),
    };
  }
  return body;
}

/** @type {Map<string, { device: string, label: string, until: number }>} */
const sessions = new Map();

/**
 * Which phone a session key goes through, asked of the backend at most
 * once per [SESSION_CACHE_MS]. Answers `{ device, label }`, or
 * `{ status, error, hint }` to refuse with.
 *
 * @param {string} key
 * @param {(name: string, params: Record<string, unknown>) => Promise<any>} call
 * @param {number} now
 */
export async function lookupSession(key, call, now = Date.now()) {
  const cached = sessions.get(key);
  if (cached && cached.until > now) return { device: cached.device, label: cached.label };
  const r = await call("session_key_proxy_check", { p_key: key });
  if (!r || r.error) {
    const msg = String(r?.error ?? "");
    const status = msg.includes("SESSION_KEY_SCOPE") ? 403 : msg.includes("NO_PROXY_PHONE") ? 503 : 401;
    return {
      status,
      error: msg || "SESSION_KEY_INVALID",
      hint: String(r?.hint ?? "This session key is unknown, has expired or was removed."),
    };
  }
  if (r.ok !== true || !r.device) {
    return { status: 503, error: "NO_PROXY_PHONE", hint: String(r.hint ?? "No gateway phone carries this session's internet.") };
  }
  const entry = { device: String(r.device), label: String(r.label ?? ""), until: now + SESSION_CACHE_MS };
  sessions.set(key, entry);
  if (sessions.size > 1000) sessions.delete(sessions.keys().next().value);
  return { device: entry.device, label: entry.label };
}

/** Forgets every cached session (tests). */
export function forgetSessions() {
  sessions.clear();
}

const USAGE = `proxy.getride.my: a test session's internet, through a GET.ride gateway phone.

  curl -H "Authorization: Bearer $GETRIDE_SESSION_KEY" https://proxy.getride.my/https://example.com/

A full admin adds a session key in Admin -> SMS / WhatsApp -> Session access,
with "Use a gateway phone's internet" ticked. See docs/session-access.md.
`;

/**
 * What the worker does with a request. [deps] is the backend call and the
 * relay to the phone's Durable Object, so tests pass fakes.
 *
 * @param {Request} request
 * @param {Record<string, any>} env
 * @param {{ rpc: (name: string, params: Record<string, unknown>) => Promise<any>,
 *           relay: (deviceId: string, req: Request) => Promise<Response>,
 *           now?: () => number }} deps
 */
export async function handle(request, env, deps) {
  const url = new URL(request.url);
  const now = deps.now ?? Date.now;

  if (url.pathname === "/" || url.pathname === "") {
    return new Response(USAGE, { status: 200, headers: { "content-type": "text/plain; charset=utf-8" } });
  }

  if (url.pathname === PHONE_PATH) {
    if ((request.headers.get("upgrade") ?? "").toLowerCase() !== "websocket") {
      return refuse(426, "UPGRADE_REQUIRED", "The gateway phone connects here with a WebSocket.");
    }
    const key = bearerFrom(request.headers) ?? url.searchParams.get("key");
    if (!key) return refuse(401, "GATEWAY_KEY_MISSING", "Send the phone's device key as Authorization: Bearer.");
    const r = await deps.rpc("gateway_key_check", { p_key: key });
    if (!r || r.error || !r.id) {
      return refuse(401, String(r?.error ?? "GATEWAY_KEY_INVALID"), String(r?.hint ?? "This phone is not paired."));
    }
    // The upgrade request itself goes on to the phone's object, which answers
    // it with the socket; only the phone's name is added.
    const req = new Request(`https://relay${PHONE_PATH}`, request);
    req.headers.set("x-phone-label", String(r.label ?? request.headers.get("x-phone-label") ?? ""));
    return deps.relay(String(r.id), req);
  }

  const target = targetFrom(url.pathname + url.search);
  if (!target) {
    return refuse(400, "NO_TARGET", "Call /https://host/path: the URL to fetch goes after the first slash.");
  }
  const key = bearerFrom(request.headers);
  if (!key) {
    return refuse(401, "SESSION_KEY_MISSING", "Send the session key as Authorization: Bearer <key>.");
  }
  const session = await lookupSession(key, deps.rpc, now());
  if (!("device" in session)) return refuse(session.status, session.error, session.hint);

  const headers = new Headers();
  for (const [n, v] of forwardHeaders(request.headers)) headers.append(n, v);
  headers.set("x-relay-target", target);
  headers.set("x-relay-phone-label", session.label);
  const body = request.method === "GET" || request.method === "HEAD" ? null : request.body;
  const req = new Request("https://relay/relay", { method: request.method, headers, body, duplex: "half" });
  return deps.relay(session.device, req);
}

/**
 * One gateway phone's relay: its WebSocket and the requests in flight.
 * Named by the phone's device row id, so a session key's phone and the
 * phone's own connection meet in the same object.
 */
export class PhoneRelay {
  /**
   * @param {any} ctx
   * @param {Record<string, any>} env
   */
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    /** @type {Map<string, { resolve: (r: Response) => void, writer: WritableStreamDefaultWriter<Uint8Array> | null, timer: any, label: string }>} */
    this.pending = new Map();
    // "ping" is answered at the edge, without waking this object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  /** @param {Request} request */
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === PHONE_PATH) return this.connectPhone(request);
    if (url.pathname === "/relay") return this.relay(request);
    if (url.pathname === "/status") {
      return Response.json({ connected: this.phone() !== null, pending: this.pending.size });
    }
    return refuse(404, "NOT_FOUND", "");
  }

  /** The phone dials in. A newer connection replaces an older one. */
  connectPhone(request) {
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.close(1000, "replaced by a newer connection");
      } catch {
        // Already gone.
      }
    }
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ label: request.headers.get("x-phone-label") ?? "" });
    return new Response(null, { status: 101, webSocket: client });
  }

  /**
   * The phone's live socket, or null. A socket the phone dropped without a
   * close frame (mobile data gone, the app killed) stays in the list, closed,
   * until the runtime notices; sending on it throws "send() after close()".
   * So only an open socket counts, and a dead one is closed on sight.
   */
  phone() {
    const sockets = this.ctx.getWebSockets();
    let live = null;
    for (const ws of sockets) {
      if (ws.readyState === WS_OPEN) {
        live = ws; // the newest open one wins
      } else {
        try {
          ws.close(1011, "stale");
        } catch {
          // Already gone.
        }
      }
    }
    return live;
  }

  /** A session's request: handed to the phone, answered as it streams back. */
  async relay(request) {
    const ws = this.phone();
    if (!ws) {
      return refuse(503, "PHONE_OFFLINE",
        "The gateway phone is not connected. On the phone, open the GET.ride Gateway app, turn the gateway on and " +
          "turn on \"Share this phone's internet\".");
    }
    const id = crypto.randomUUID();
    const label = request.headers.get("x-relay-phone-label") ?? "";
    const headers = [];
    for (const [n, v] of request.headers) {
      if (n.startsWith("x-relay-")) continue;
      headers.push([n, v]);
    }
    const answer = new Promise((resolve) => {
      this.pending.set(id, { resolve, writer: null, timer: null, label });
    });
    this.arm(id, "The gateway phone did not answer in time.");
    try {
      ws.send(JSON.stringify({ id, method: request.method, url: request.headers.get("x-relay-target"), headers }));
      if (request.body) {
        const reader = request.body.getReader();
        let total = 0;
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          total += value.length;
          if (total > MAX_REQUEST_BODY) {
            this.finish(id, refuse(413, "BODY_TOO_LARGE", `A request body may be at most ${MAX_REQUEST_BODY} bytes.`));
            ws.send(JSON.stringify({ id, abort: true }));
            return answer;
          }
          for (const chunk of toChunks(value)) ws.send(JSON.stringify({ id, chunk }));
        }
      }
      ws.send(JSON.stringify({ id, end: true }));
    } catch (e) {
      // The socket died between the pick and the send: drop it, so the next
      // request sees the phone as offline (or its newer connection).
      try {
        ws.close(1011, "send failed");
      } catch {
        // Already gone.
      }
      this.finish(id, refuse(503, "PHONE_OFFLINE",
        `The gateway phone's connection dropped (${String(e?.message ?? e)}). It reconnects by itself: try again in a few seconds.`));
    }
    return answer;
  }

  /** Starts (or restarts) the clock on a request. */
  arm(id, why) {
    const p = this.pending.get(id);
    if (!p) return;
    if (p.timer) clearTimeout(p.timer);
    p.timer = setTimeout(() => this.fail(id, "PHONE_TIMEOUT", why), PHONE_TIMEOUT_MS);
  }

  /** Answers a request that has no response yet, or ends its stream with an error. */
  fail(id, error, hint) {
    const p = this.pending.get(id);
    if (!p) return;
    if (p.writer) {
      p.writer.abort(new Error(error)).catch(() => {});
      this.pending.delete(id);
      if (p.timer) clearTimeout(p.timer);
      return;
    }
    this.finish(id, refuse(502, error, hint));
  }

  finish(id, response) {
    const p = this.pending.get(id);
    if (!p) return;
    this.pending.delete(id);
    if (p.timer) clearTimeout(p.timer);
    p.resolve(response);
  }

  /** A frame from the phone. */
  webSocketMessage(_ws, message) {
    if (typeof message !== "string") return;
    let m;
    try {
      m = JSON.parse(message);
    } catch {
      return;
    }
    const p = m && this.pending.get(m.id);
    if (!p) return;
    if (m.error !== undefined) {
      this.fail(m.id, "PHONE_ERROR", String(m.error));
      return;
    }
    if (m.status !== undefined && !p.writer) {
      const status = Number(m.status);
      const headers = responseHeaders(m.headers, p.label);
      if (NO_BODY.has(status)) {
        this.finish(m.id, new Response(null, { status, headers }));
        return;
      }
      const { readable, writable } = new TransformStream();
      p.writer = writable.getWriter();
      this.arm(m.id, "The gateway phone stopped sending.");
      p.resolve(new Response(readable, { status, headers }));
      return;
    }
    if (typeof m.chunk === "string" && p.writer) {
      this.arm(m.id, "The gateway phone stopped sending.");
      p.writer.write(fromBase64(m.chunk)).catch(() => this.fail(m.id, "SESSION_GONE", ""));
      return;
    }
    if (m.end === true) {
      if (p.writer) p.writer.close().catch(() => {});
      else this.finish(m.id, new Response(null, { status: 502, headers: responseHeaders([], p.label) }));
      if (p.timer) clearTimeout(p.timer);
      this.pending.delete(m.id);
    }
  }

  webSocketClose(ws) {
    try {
      ws.close(1000, "closed");
    } catch {
      // Already closed.
    }
    // An old connection closing while a newer one is up (the phone
    // reconnected) is not an outage for the requests on the newer one.
    if (!this.phone()) this.dropAll("The gateway phone disconnected.");
  }

  webSocketError(ws) {
    try {
      ws.close(1011, "error");
    } catch {
      // Already closed.
    }
    if (!this.phone()) this.dropAll("The gateway phone's connection failed.");
  }

  dropAll(why) {
    for (const id of [...this.pending.keys()]) this.fail(id, "PHONE_DISCONNECTED", why);
  }
}
