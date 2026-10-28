# Visitor stats (office NAS)

How many people visit getride.my and qr.getride.my, which pages, and where
they came from, counted by **[Umami](https://umami.is)** (MIT) on the office
NAS. Admin › Settings › Office NAS › **Visitor stats** shows today's
visitors, install page views, the top page and the top source.

- **No cookies, no personal data, no banner needed.** Umami keeps no IP
  addresses and sets no cookies; a browser asking not to be tracked isn't
  counted.
- **Only the public pages** are counted: the landing page, `/install/…`, and
  the QR pages (`qr.getride.my/ref|me|now/<token>`, counted as
  `/ref/:token`: the token is never sent). The signed-in app and the admin
  are never counted. The referrer is cut to its site (`https://wa.me`).
- **The NAS can be off.** The site loads the counting script `async`; when
  the NAS doesn't answer, the script just doesn't load and visits aren't
  counted. Nothing else notices. The Admin tab then says "NAS off".
- **Switched on at build time**: the site sends nothing until the web build
  has both `STATS_SCRIPT_URL` and `STATS_WEBSITE_ID` (step 5).

## How it is reached: Cloudflare Tunnel

Visitors' browsers send their counts to Umami, and the get.ride server
function reads today's numbers from it, so Umami needs a public address.
The NAS doesn't open ports, so it gets one through a **Cloudflare Tunnel**:
the `cloudflared` container on the NAS keeps an outgoing connection to
Cloudflare, and Cloudflare sends `https://stats.getride.my` down it. No
router change, no port open, and Cloudflare provides the certificate.

```
visitor's browser ──https──▶ stats.getride.my (Cloudflare) ◀──tunnel── cloudflared ──▶ umami:3000 ──▶ umami-db
get.ride nas-stats ──https──▶ stats.getride.my /api/…            (all on the NAS, no port open)
```

getride.my is already on Cloudflare (the `*.getride.my` worker,
`cloudflare/subdomain-proxy`). That worker leaves `stats` alone (it is in
its `PASS_THROUGH` list in `wrangler.toml`); if the repository variable
`SUBDOMAIN_PROXY_PASS_THROUGH` is set, add `stats` to it too, or the
worker would answer for stats.getride.my instead of the tunnel.

## What the NAS needs

- Synology DSM 7.2 or later with **Container Manager**, on an x86-64 model.
- About 300 MB of memory (Umami and its Postgres; capped at 1.3 GB) and well
  under 1 GB of disk a year at get.ride's traffic.

## 1. Make the Cloudflare Tunnel

1. Cloudflare dashboard → **Zero Trust** → **Networks** → **Tunnels** →
   **Create a tunnel**.
2. Pick **Cloudflared**, name it `getride-stats`, **Save tunnel**.
3. On the install page, pick **Docker** and copy the long token after
   `--token` in the command shown: that is the `TUNNEL_TOKEN`. Don't run the
   command: the compose file runs cloudflared for you.
4. **Next** → **Public Hostname**: subdomain `stats`, domain `getride.my`,
   path empty, service type **HTTP**, URL `umami:3000`. **Save tunnel**.
   Cloudflare makes the `stats` DNS record itself.

The tunnel shows **Healthy** once the containers are up (step 3).

(Already running a tunnel on the NAS, e.g. `getride-face` for the face match
server? Make a separate one anyway: each compose file's `cloudflared` only
reaches the containers next to it.)

## 2. Put the files on the NAS

1. **File Station**: make the folder `docker/nas-stats` (in the `docker`
   shared folder, see `deploy/doc-reader/README.md` step 2 if it doesn't
   exist) and upload `docker-compose.yml` and `.env.example` into it.
2. Over SSH:

   ```sh
   cd /volume1/docker/nas-stats
   cp .env.example .env
   sed -i "s/^UMAMI_DB_PASSWORD=.*/UMAMI_DB_PASSWORD=$(openssl rand -hex 16)/" .env
   sed -i "s/^UMAMI_APP_SECRET=.*/UMAMI_APP_SECRET=$(openssl rand -hex 32)/" .env
   vi .env          # paste TUNNEL_TOKEN from step 1
   chmod 600 .env
   mkdir -p pgdata
   ```

## 3. Start it (SSH)

```sh
cd /volume1/docker/nas-stats
sudo docker compose up -d
sudo docker logs -f nas-stats-tunnel     # "Registered tunnel connection" x4
```

If `docker compose` isn't found, use `docker-compose`. Container Manager
(**Project** → **Create**, path `docker/nas-stats`, **Use existing
docker-compose.yml**) also runs it once `pgdata` is made.

Open https://stats.getride.my: Umami's sign-in page.

## 4. Set up Umami

1. Sign in as `admin` / `umami` and **change that password at once**
   (Profile → Change password). Umami's sign-in page is public.
2. **Settings** → **Websites** → **Add website**: name `get.ride`, domain
   `getride.my`. Open it (**Edit**) and copy the **Website ID**
   (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`). One website covers both
   getride.my and qr.getride.my.
3. **Settings** → **Users** → **Create user**: username `getride`, a long
   random password, role **View only**. get.ride's server reads the stats
   as this user.

## 5. Connect it to get.ride

1. **Admin › Settings › API Keys** → **Umami** → **Umami (view-only user)**:
   add a key, the address, a space, then the user and password:

   ```
   https://stats.getride.my getride:THE-PASSWORD
   ```

2. **Admin › Settings › Office NAS › Visitor stats**: paste the Website ID,
   **Save**. The tiles fill in (zeros until someone visits).
3. Switch the counting on for the site: GitHub → the repository → **Settings
   → Secrets and variables → Actions → Variables**:

   | Variable | Value |
   |---|---|
   | `STATS_SCRIPT_URL` | `https://stats.getride.my/s.js` |
   | `STATS_WEBSITE_ID` | the Website ID |

   The next web deploy puts them into the site (`scripts/ci/stats_meta.sh`
   fills `<meta name="getride-stats">` in `index.html`; `web/stats.js` reads
   it). Delete either variable and redeploy to stop counting.

The site's content policy already allows the script from
`https://stats.getride.my` (`deploy/vercel_output_config.json`).

## Updating

Change `UMAMI_IMAGE` in `.env` (or the default in `docker-compose.yml`) and
`sudo docker compose pull && sudo docker compose up -d`. Umami updates its
own tables on start. The data in `pgdata/` is kept.

## If something is wrong

| You see | Do this |
|---|---|
| Admin says **NAS off** | The NAS, the containers or the tunnel are down: `sudo docker compose ps`; the tunnel's log (`docker logs nas-stats-tunnel`). |
| Admin says Umami **refused** the name and password | The key in API Keys doesn't match the `getride` user: set its password again in Umami and in API Keys. |
| Admin says **no website ID** / **no Umami key** | Step 5. |
| stats.getride.my shows the get.ride app | The `*.getride.my` worker answered: add `stats` to `SUBDOMAIN_PROXY_PASS_THROUGH` (see above) and redeploy the worker. |
| stats.getride.my: Cloudflare error 1033 / 530 | The tunnel isn't connected: check `TUNNEL_TOKEN` in `.env`, then `sudo docker compose up -d`. |
| Zero visitors after a day | The site build doesn't have the variables (step 5.3), or a browser blocker: the page source should show `<meta name="getride-stats" content="https://stats.getride.my/s.js …">`. |

## Tests

- `scripts/ci/web_stats_test.ts`: which pages are counted and how, the
  build switch.
- `supabase/functions/_shared/nas_stats_test.ts`: the key, today's range in
  Malaysia time, reading Umami 2 and 3, "NAS off" and the other states.
- `supabase/tests/nas_testdb_stats_0321.sql`: the settings and who may read
  them.
