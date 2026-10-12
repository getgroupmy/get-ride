/**
 * Make sure the getride.my zone has a proxied wildcard record, so the
 * subdomain proxy worker (cloudflare/subdomain-proxy) actually runs.
 *
 *     deno run --allow-env --allow-net=api.cloudflare.com \
 *       scripts/ci/cloudflare_wildcard.ts getride.my qr.getride.my
 *
 * The first argument is the zone; any others are hosts to check for an
 * explicit record that would bypass the worker.
 *
 * Run by .github/workflows/cloudflare-worker.yml right after the worker is
 * deployed (never before: a proxied wildcard with no worker behind it
 * would send every subdomain to the apex's origin with the wrong SNI, and
 * Vercel would answer 525).
 *
 * A worker route only fires for hostnames whose DNS record is **proxied**
 * (orange cloud). Without any record a subdomain does not resolve at all;
 * with a DNS-only (grey) one it goes straight to wherever the record
 * points and the worker never sees it. So:
 *
 *   1. No record named `*.getride.my`: one is created, `CNAME * -> getride.my`,
 *      proxied. Its content does not matter -- with the worker in front, no
 *      request reaches it -- it only has to be a valid, proxiable target.
 *   2. A wildcard exists and is proxied: nothing to do.
 *   3. A wildcard exists and is not proxied: a warning. It is somebody's
 *      record and is never modified.
 *   4. For each extra host (qr.getride.my): an explicit record of that name
 *      overrides the wildcard. If it is DNS only it bypasses the worker,
 *      which is fine only if it points at Vercel and Vercel has the domain;
 *      a warning says so. A proxied one still goes through the worker.
 *
 * The wildcard is the only record ever created, and no record is ever
 * modified or deleted. Never fails the job: a warning is the output. Transient API errors are retried
 * (the Cloudflare client from vercel_domains.ts).
 *
 * Reads CLOUDFLARE_API_TOKEN (Zone -> DNS -> Edit and Zone -> Zone -> Read
 * on getride.my), sent only in the Authorization header.
 *
 * Endpoints (https://developers.cloudflare.com/api/):
 *   GET  /client/v4/zones?name={zone}
 *   GET  /client/v4/zones/{id}/dns_records?name={fqdn}
 *   POST /client/v4/zones/{id}/dns_records
 */
import { Cloudflare, cloudflareErrorOf, type Report } from "./vercel_domains.ts";

/** What the record's comment says, so somebody in the dashboard knows why it is there. */
export const COMMENT = "GET.ride subdomain proxy worker (cloudflare/subdomain-proxy) -- must stay proxied";

// deno-lint-ignore no-explicit-any
type Json = any;

function describe(r: Json): string {
  return `${r?.type} ${r?.content} (${r?.proxied ? "proxied" : "DNS only"})`;
}

/** Records named exactly [name] in zone [zoneId], or an error string. */
async function recordsNamed(cf: Cloudflare, zoneId: string, name: string): Promise<Json[] | string> {
  const r = await cf.call(
    "GET",
    `/zones/${encodeURIComponent(zoneId)}/dns_records?name=${encodeURIComponent(name)}&per_page=100`,
  );
  if (r.status !== 200 || r.body?.success === false) return cloudflareErrorOf(r);
  return (r.body?.result ?? []).filter((x: Json) => String(x?.name ?? "").toLowerCase() === name);
}

/** Ensures the wildcard and reports on [checkHosts]. Never throws. */
export async function ensureWildcard(
  cf: Cloudflare,
  zone: string,
  checkHosts: string[] = [],
): Promise<Report> {
  const notes: string[] = [];
  const warnings: string[] = [];
  const wildcard = `*.${zone}`;

  const z = await cf.call("GET", `/zones?name=${encodeURIComponent(zone)}`);
  if (z.status !== 200 || z.body?.success === false) {
    warnings.push(`Could not look up the ${zone} zone on Cloudflare (${cloudflareErrorOf(z)}).`);
    return { notes, warnings };
  }
  const hit = (z.body?.result ?? []).find((x: Json) => x?.name === zone);
  if (!hit?.id) {
    warnings.push(
      `The Cloudflare token cannot see the ${zone} zone. Give it Zone -> DNS -> Edit and ` +
        `Zone -> Zone -> Read on ${zone}.`,
    );
    return { notes, warnings };
  }
  const zoneId = String(hit.id);

  const existing = await recordsNamed(cf, zoneId, wildcard);
  if (typeof existing === "string") {
    warnings.push(`Could not list the ${wildcard} records (${existing}).`);
  } else if (!existing.length) {
    const created = await cf.call("POST", `/zones/${encodeURIComponent(zoneId)}/dns_records`, {
      type: "CNAME",
      name: wildcard,
      content: zone,
      ttl: 1,
      proxied: true,
      comment: COMMENT,
    });
    if (created.status >= 200 && created.status < 300 && created.body?.success !== false) {
      notes.push(`Created ${wildcard} CNAME ${zone}, proxied: every subdomain now reaches the worker.`);
    } else {
      warnings.push(
        `Could not create the wildcard record (${cloudflareErrorOf(created)}). Add it in Cloudflare -> DNS: ` +
          `CNAME, name *, target ${zone}, Proxied.`,
      );
    }
  } else if (existing.some((r: Json) => r?.proxied === true)) {
    notes.push(`${wildcard} is there and proxied (${existing.map(describe).join(", ")}).`);
  } else {
    warnings.push(
      `${wildcard} exists but is DNS only (${existing.map(describe).join(", ")}), so the worker route never ` +
        `fires for it. Left as it is: switch it to Proxied (orange cloud) in Cloudflare -> DNS.`,
    );
  }

  for (const host of checkHosts) {
    const recs = await recordsNamed(cf, zoneId, host);
    if (typeof recs === "string") {
      warnings.push(`Could not list the ${host} records (${recs}).`);
      continue;
    }
    if (!recs.length) {
      notes.push(`${host} has no record of its own: the wildcard covers it, through the worker.`);
      continue;
    }
    const grey = recs.filter((r: Json) => r?.proxied !== true);
    if (!grey.length) {
      notes.push(`${host} has its own proxied record (${recs.map(describe).join(", ")}); the worker still serves it.`);
      continue;
    }
    warnings.push(
      `${host} has its own DNS-only record (${grey.map(describe).join(", ")}), which overrides the wildcard ` +
        `and bypasses the worker. That works only if it points at Vercel and the Vercel project has ${host}. ` +
        `To serve it through the worker instead, delete that record (or switch it to Proxied).`,
    );
  }

  return { notes, warnings };
}

async function main(): Promise<void> {
  const [zone = "getride.my", ...hosts] = Deno.args.map((a) => a.trim().toLowerCase()).filter(Boolean);
  const token = (Deno.env.get("CLOUDFLARE_API_TOKEN") ?? "").trim();
  const lines: string[] = [];
  if (!token) {
    console.log("::warning::CLOUDFLARE_API_TOKEN is not set; the wildcard record was not checked.");
    return;
  }
  const report = await ensureWildcard(new Cloudflare(token), zone, hosts);
  for (const n of report.notes) {
    console.log(n);
    lines.push(`* ${n}`);
  }
  for (const w of report.warnings) {
    console.log(`::warning::${w}`);
    lines.push(`* :warning: ${w}`);
  }
  const summary = Deno.env.get("GITHUB_STEP_SUMMARY");
  if (summary && lines.length) {
    await Deno.writeTextFile(summary, ["", "### Wildcard DNS", "", ...lines, ""].join("\n"), { append: true });
  }
}

if (import.meta.main) {
  try {
    await main();
  } catch (e) {
    console.log(`::warning::Wildcard check stopped: ${e instanceof Error ? e.message : e}`);
  }
}
