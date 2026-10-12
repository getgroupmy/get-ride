/**
 * Make sure every domain in deploy/domains.txt is served by the Vercel
 * project, and that its DNS points there.
 *
 *     deno run --allow-read --allow-env --allow-net=api.vercel.com \
 *       scripts/ci/vercel_domains.ts deploy/domains.txt
 *
 * Run by .github/workflows/deploy-web.yml after a production deploy, so a
 * new subdomain the app needs (qr.getride.my, for My QR's app links) is
 * registered by committing one line rather than by somebody clicking
 * through the Vercel dashboard. For each listed domain:
 *
 *   1. Added to the project if it is not on it yet. Domains the project
 *      already has and that are not listed are left alone: the list says
 *      what must exist, not everything that may.
 *   2. Its DNS is checked. If Vercel says it is misconfigured and the
 *      zone it lives in is on Vercel DNS, the CNAME is created (unless a
 *      record of that name is already there -- an existing record is
 *      somebody's decision and is never overwritten). If the zone is
 *      elsewhere, a warning names the exact record to add -- unless the zone
 *      is on Cloudflare and CLOUDFLARE_API_TOKEN is set, in which case the
 *      CNAME is created there (DNS only, never proxied: Vercel has to see
 *      its own address to issue the certificate), under the same rule of
 *      never overwriting a record that is already there.
 *
 * It never fails the deploy: the site is already live by now, and a domain
 * that could not be registered is a warning to act on, not a red build.
 * Transient API errors (429, 5xx, a dropped connection) are retried.
 *
 * Reads VERCEL_TOKEN, VERCEL_ORG_ID (the team) and VERCEL_PROJECT_ID, and
 * the optional CLOUDFLARE_API_TOKEN (Zone -> DNS -> Edit on the zone). Each
 * token goes in its own Authorization header and nowhere else.
 *
 * Endpoints (https://vercel.com/docs/rest-api):
 *   GET  /v9/projects/{project}/domains/{domain}    on the project?
 *   POST /v10/projects/{project}/domains            add {name}
 *   POST /v9/projects/{project}/domains/{domain}/verify
 *   GET  /v6/domains/{domain}/config                misconfigured?
 *   GET  /v5/domains/{zone}                         zone on Vercel DNS?
 *   GET  /v4/domains/{zone}/records                 existing records
 *   POST /v2/domains/{zone}/records                 create the CNAME
 *
 * Cloudflare (https://developers.cloudflare.com/api/):
 *   GET  /client/v4/zones?name={zone}                    the zone's id
 *   GET  /client/v4/zones/{id}/dns_records?name={fqdn}   existing records
 *   POST /client/v4/zones/{id}/dns_records               create the CNAME
 */

export const API = "https://api.vercel.com";

export const CLOUDFLARE_API = "https://api.cloudflare.com/client/v4";

/** What Vercel asks a subdomain to CNAME to when it recommends nothing. */
export const DEFAULT_CNAME = "cname.vercel-dns.com";

/** What Vercel asks an apex to point at when it recommends nothing. */
export const DEFAULT_A = "76.76.21.21";

const HOSTNAME = /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;

/** The domains in a domains.txt: one per line, `#` comments, no repeats. */
export function parseDomainList(text: string): { domains: string[]; rejected: string[] } {
  const domains: string[] = [];
  const rejected: string[] = [];
  for (const line of text.split("\n")) {
    const s = line.replace(/#.*/, "").trim().toLowerCase().replace(/\.$/, "");
    if (!s) continue;
    if (!HOSTNAME.test(s)) rejected.push(s);
    else if (!domains.includes(s)) domains.push(s);
  }
  return { domains, rejected };
}

/**
 * The zones [domain] could be a record in, closest first:
 * `a.qr.getride.my` → `qr.getride.my`, `getride.my`. Empty for a
 * two-label domain, which is its own zone.
 */
export function zoneCandidates(domain: string): string[] {
  const labels = domain.split(".");
  const out: string[] = [];
  for (let i = 1; i <= labels.length - 2; i++) out.push(labels.slice(i).join("."));
  return out;
}

/** The record name of [domain] inside [zone]: `qr` for qr.getride.my. */
export function recordName(domain: string, zone: string): string {
  if (domain === zone) return "";
  if (!domain.endsWith(`.${zone}`)) throw new Error(`${domain} is not in ${zone}`);
  return domain.slice(0, -(zone.length + 1));
}

// deno-lint-ignore no-explicit-any
type Json = any;

/** The CNAME target Vercel recommends for a subdomain (rank 1 first). */
export function cnameTarget(config: Json): string {
  const rec = config?.recommendedCNAME;
  if (Array.isArray(rec) && rec.length) {
    const best = [...rec].sort((a, b) => (a?.rank ?? 99) - (b?.rank ?? 99))[0];
    if (typeof best?.value === "string" && best.value) return best.value.replace(/\.$/, "");
  }
  return DEFAULT_CNAME;
}

/** The A record Vercel recommends for an apex. */
export function aTarget(config: Json): string {
  const rec = config?.recommendedIPv4;
  if (Array.isArray(rec) && rec.length) {
    const best = [...rec].sort((a, b) => (a?.rank ?? 99) - (b?.rank ?? 99))[0];
    const v = Array.isArray(best?.value) ? best.value[0] : best?.value;
    if (typeof v === "string" && v) return v;
  }
  return DEFAULT_A;
}

/** Whether a `/v5/domains/{zone}` answer says the zone is on Vercel DNS. */
export function isVercelDns(info: Json): boolean {
  const d = info?.domain ?? info;
  if (!d) return false;
  if (d.serviceType === "zeit.world") return true;
  const ns: string[] = (d.nameservers ?? []).map((s: string) => s.toLowerCase().replace(/\.$/, ""));
  const want: string[] = (d.intendedNameservers ?? []).map((s: string) => s.toLowerCase().replace(/\.$/, ""));
  return ns.length > 0 && want.length > 0 && ns.every((n) => want.includes(n));
}

/** Whether a status is worth trying again. */
export function isTransient(status: number): boolean {
  return status === 429 || status >= 500;
}

export interface Reply {
  status: number;
  body: Json;
}

type Fetch = (url: string, init: RequestInit) => Promise<Response>;

/** A Vercel API client that retries what is worth retrying. */
export class Vercel {
  constructor(
    private token: string,
    private teamId: string | null,
    private fetcher: Fetch = fetch,
    private attempts = 4,
    private delayMs = 2000,
  ) {}

  url(path: string): string {
    if (!this.teamId) return `${API}${path}`;
    return `${API}${path}${path.includes("?") ? "&" : "?"}teamId=${encodeURIComponent(this.teamId)}`;
  }

  async call(method: string, path: string, body?: unknown): Promise<Reply> {
    let delay = this.delayMs;
    for (let n = 1;; n++) {
      try {
        const res = await this.fetcher(this.url(path), {
          method,
          headers: {
            authorization: `Bearer ${this.token}`,
            ...(body === undefined ? {} : { "content-type": "application/json" }),
          },
          body: body === undefined ? undefined : JSON.stringify(body),
        });
        const text = await res.text();
        let parsed: Json = null;
        try {
          parsed = text ? JSON.parse(text) : null;
        } catch {
          parsed = { raw: text.slice(0, 300) };
        }
        if (!isTransient(res.status) || n >= this.attempts) return { status: res.status, body: parsed };
      } catch (e) {
        if (n >= this.attempts) return { status: 0, body: { error: { message: String(e) } } };
      }
      await new Promise((r) => setTimeout(r, delay));
      delay *= 2;
    }
  }
}

/** The same client against Cloudflare's API (no team parameter). */
export class Cloudflare extends Vercel {
  constructor(token: string, fetcher: Fetch = fetch, attempts = 4, delayMs = 2000) {
    super(token, null, fetcher, attempts, delayMs);
  }

  override url(path: string): string {
    return `${CLOUDFLARE_API}${path}`;
  }
}

/** Cloudflare's error messages in [r], for a warning. */
export function cloudflareErrorOf(r: Reply): string {
  const errs = Array.isArray(r.body?.errors) ? r.body.errors : [];
  const msg = errs.map((e: Json) => `${e?.code ?? ""} ${e?.message ?? ""}`.trim()).join("; ") ||
    r.body?.raw || "no message";
  return `HTTP ${r.status}: ${msg}`;
}

/**
 * Creates [domain] CNAME [target] on Cloudflare, DNS only. Null when the
 * domain's zone is not on this Cloudflare account (so the caller can fall
 * back to naming the record); otherwise what happened.
 */
export async function ensureCloudflareRecord(
  cf: Cloudflare,
  domain: string,
  target: string,
): Promise<Report | null> {
  const notes: string[] = [];
  const warnings: string[] = [];
  let zoneId: string | null = null;
  let zone = "";
  for (const z of zoneCandidates(domain)) {
    const r = await cf.call("GET", `/zones?name=${encodeURIComponent(z)}`);
    if (r.status !== 200) {
      warnings.push(`${domain}: could not look up ${z} on Cloudflare (${cloudflareErrorOf(r)}).`);
      return { notes, warnings };
    }
    const hit = (r.body?.result ?? []).find((x: Json) => x?.name === z);
    if (hit?.id) {
      zoneId = String(hit.id);
      zone = z;
      break;
    }
  }
  if (!zoneId) return null;

  const id = encodeURIComponent(zoneId);
  const records = await cf.call("GET", `/zones/${id}/dns_records?name=${encodeURIComponent(domain)}`);
  if (records.status !== 200) {
    warnings.push(`${domain}: could not list its Cloudflare records (${cloudflareErrorOf(records)}).`);
    return { notes, warnings };
  }
  const existing = (records.body?.result ?? []).filter((r: Json) => r?.name === domain);
  if (existing.length) {
    const ours = existing.find(
      (r: Json) => r.type === "CNAME" && String(r.content ?? "").replace(/\.$/, "") === target,
    );
    if (ours?.proxied === true) {
      warnings.push(
        `${domain}: the Cloudflare CNAME is proxied (orange cloud). Vercel cannot issue its certificate ` +
          `through the proxy: set it to DNS only (grey cloud) in Cloudflare.`,
      );
    } else if (ours) {
      notes.push(`${domain}: the Cloudflare CNAME is there; DNS is still settling.`);
    } else {
      warnings.push(
        `${domain}: Cloudflare already has a record named ${domain} (` +
          existing.map((r: Json) => `${r.type} ${r.content}`).join(", ") +
          `), left as it is. For the site it should be: ${domain} CNAME ${target}, DNS only.`,
      );
    }
    return { notes, warnings };
  }

  const created = await cf.call("POST", `/zones/${id}/dns_records`, {
    type: "CNAME",
    name: domain,
    content: target,
    ttl: 1,
    proxied: false,
    comment: "GET.ride web app (deploy/domains.txt)",
  });
  if (created.status >= 200 && created.status < 300 && created.body?.success !== false) {
    notes.push(`${domain}: created CNAME ${target} in Cloudflare (${zone}, DNS only).`);
  } else {
    warnings.push(
      `${domain}: could not create the Cloudflare record (${cloudflareErrorOf(created)}). ` +
        `Add: ${domain} CNAME ${target}, DNS only.`,
    );
  }
  return { notes, warnings };
}

/** Vercel's error message in [r], for a warning. */
export function errorOf(r: Reply): string {
  const e = r.body?.error;
  const msg = e?.message ?? r.body?.raw ?? "no message";
  return `HTTP ${r.status}${e?.code ? ` ${e.code}` : ""}: ${msg}`;
}

export interface Report {
  notes: string[];
  warnings: string[];
}

function verificationText(v: Json): string {
  if (!Array.isArray(v) || !v.length) return "";
  return " Add " + v.map((r: Json) => `${r.type} ${r.domain} "${r.value}"`).join(", ") + " to verify it.";
}

/** Ensures one domain. Never throws: what went wrong is a warning. */
export async function ensureDomain(
  api: Vercel,
  project: string,
  domain: string,
  cf: Cloudflare | null = null,
): Promise<Report> {
  const notes: string[] = [];
  const warnings: string[] = [];
  const p = encodeURIComponent(project);
  const d = encodeURIComponent(domain);

  // 1. On the project.
  let onProject = await api.call("GET", `/v9/projects/${p}/domains/${d}`);
  if (onProject.status === 404) {
    const added = await api.call("POST", `/v10/projects/${p}/domains`, { name: domain });
    if (added.status >= 200 && added.status < 300) {
      notes.push(`${domain}: added to the project.`);
      onProject = added;
    } else {
      // A 409 can be "already on this project" (a race with the
      // dashboard) as well as "on another project": ask again.
      const again = await api.call("GET", `/v9/projects/${p}/domains/${d}`);
      if (again.status === 200) {
        onProject = again;
      } else {
        warnings.push(`${domain}: could not add it to the Vercel project (${errorOf(added)}).`);
        return { notes, warnings };
      }
    }
  } else if (onProject.status === 200) {
    notes.push(`${domain}: already on the project.`);
  } else {
    warnings.push(`${domain}: could not read the project's domains (${errorOf(onProject)}).`);
    return { notes, warnings };
  }

  if (onProject.body?.verified === false) {
    const v = await api.call("POST", `/v9/projects/${p}/domains/${d}/verify`);
    if (!(v.status === 200 && v.body?.verified === true)) {
      warnings.push(
        `${domain}: on the project but not verified (it is claimed by another Vercel account).` +
          verificationText(onProject.body?.verification),
      );
    }
  }

  // 2. DNS.
  const config = await api.call("GET", `/v6/domains/${d}/config`);
  if (config.status !== 200) {
    warnings.push(`${domain}: could not read its DNS configuration (${errorOf(config)}).`);
    return { notes, warnings };
  }
  if (config.body?.misconfigured === false) {
    notes.push(`${domain}: DNS is configured.`);
    return { notes, warnings };
  }

  const zones = zoneCandidates(domain);
  if (!zones.length) {
    warnings.push(`${domain}: DNS is not pointing at Vercel. Add: ${domain} A ${aTarget(config.body)}`);
    return { notes, warnings };
  }
  const target = cnameTarget(config.body);

  // DNS outside Vercel: on Cloudflare with a token, the record is made
  // there; anywhere else it is named for somebody to add.
  const viaCloudflare = async (): Promise<boolean> => {
    if (!cf) return false;
    const r = await ensureCloudflareRecord(cf, domain, target);
    if (!r) return false;
    notes.push(...r.notes);
    warnings.push(...r.warnings);
    return true;
  };

  let zone: string | null = null;
  let vercelDns = false;
  for (const z of zones) {
    const info = await api.call("GET", `/v5/domains/${encodeURIComponent(z)}`);
    if (info.status === 200) {
      zone = z;
      vercelDns = isVercelDns(info.body);
      break;
    }
  }
  if (!zone) {
    if (await viaCloudflare()) return { notes, warnings };
    warnings.push(
      `${domain}: DNS is not pointing at Vercel, and its zone is not in this Vercel team. ` +
        `Add this record at your DNS provider: ${domain} CNAME ${target}`,
    );
    return { notes, warnings };
  }
  const name = recordName(domain, zone);
  const record = `${name} CNAME ${target} (in the ${zone} zone, i.e. ${domain} -> ${target})`;
  if (!vercelDns) {
    if (await viaCloudflare()) return { notes, warnings };
    warnings.push(
      `${domain}: DNS is not pointing at Vercel and ${zone} is not on Vercel DNS. ` +
        `Add this record at your DNS provider: ${record}`,
    );
    return { notes, warnings };
  }

  const z = encodeURIComponent(zone);
  const records = await api.call("GET", `/v4/domains/${z}/records?limit=100`);
  if (records.status !== 200) {
    warnings.push(`${domain}: could not list the ${zone} records (${errorOf(records)}). Add: ${record}`);
    return { notes, warnings };
  }
  const existing = (records.body?.records ?? []).filter((r: Json) => (r?.name ?? "") === name);
  if (existing.length) {
    const same = existing.some(
      (r: Json) => r.type === "CNAME" && String(r.value ?? "").replace(/\.$/, "") === target,
    );
    if (same) notes.push(`${domain}: the CNAME is there; DNS is still settling.`);
    else {
      warnings.push(
        `${domain}: ${zone} already has a record named "${name}" (` +
          existing.map((r: Json) => `${r.type} ${r.value}`).join(", ") +
          `), left as it is. For the site it should be: ${record}`,
      );
    }
    return { notes, warnings };
  }
  const created = await api.call("POST", `/v2/domains/${z}/records`, {
    name,
    type: "CNAME",
    value: target,
    ttl: 60,
    comment: "GET.ride web app (deploy/domains.txt)",
  });
  if (created.status >= 200 && created.status < 300) {
    notes.push(`${domain}: created ${name} CNAME ${target} in Vercel DNS.`);
  } else {
    warnings.push(`${domain}: could not create the record (${errorOf(created)}). Add: ${record}`);
  }
  return { notes, warnings };
}

/** The team query parameter: only a team id is one. */
export function teamOf(orgId: string | undefined): string | null {
  const s = (orgId ?? "").trim();
  return s.startsWith("team_") ? s : null;
}

async function main(): Promise<void> {
  const file = Deno.args[0] ?? "deploy/domains.txt";
  const token = Deno.env.get("VERCEL_TOKEN") ?? "";
  const project = Deno.env.get("VERCEL_PROJECT_ID") ?? "";
  const lines: string[] = [];
  const warn = (w: string) => {
    console.log(`::warning::${w}`);
    lines.push(`* :warning: ${w}`);
  };

  if (!token || !project) {
    console.log("::notice::VERCEL_TOKEN or VERCEL_PROJECT_ID not set; domains not checked.");
  } else {
    let text = "";
    try {
      text = await Deno.readTextFile(file);
    } catch {
      warn(`${file} could not be read; domains not checked.`);
    }
    const { domains, rejected } = parseDomainList(text);
    for (const r of rejected) warn(`${file}: "${r}" is not a domain name; skipped.`);
    const api = new Vercel(token, teamOf(Deno.env.get("VERCEL_ORG_ID")));
    const cfToken = (Deno.env.get("CLOUDFLARE_API_TOKEN") ?? "").trim();
    const cf = cfToken ? new Cloudflare(cfToken) : null;
    for (const domain of domains) {
      let report: Report;
      try {
        report = await ensureDomain(api, project, domain, cf);
      } catch (e) {
        report = { notes: [], warnings: [`${domain}: ${e instanceof Error ? e.message : e}`] };
      }
      for (const n of report.notes) {
        console.log(n);
        lines.push(`* ${n}`);
      }
      report.warnings.forEach(warn);
    }
  }

  const summary = Deno.env.get("GITHUB_STEP_SUMMARY");
  if (summary && lines.length) {
    await Deno.writeTextFile(summary, ["", "### Domains", "", ...lines, ""].join("\n"), { append: true });
  }
}

if (import.meta.main) {
  try {
    await main();
  } catch (e) {
    // Never the deploy's failure: the site is live already.
    console.log(`::warning::Domain registration stopped: ${e instanceof Error ? e.message : e}`);
  }
}
