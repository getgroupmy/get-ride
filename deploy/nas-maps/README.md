# Maps on the office NAS

Routes, place search and the web map for **Malaysia, Singapore and Brunei**,
from OpenStreetMap, on the office NAS. Once it is connected, Admin › Maps can
pick **Office NAS (OpenStreetMap)** in any list. Use it ahead of Google: it
is free, and GET.ride asks the next provider whenever the NAS is off or slow.
Admin › Settings › Office NAS › Maps shows how it is doing, what it answered,
and roughly what that saved.

| Part | Software | Used for |
|---|---|---|
| Routes | [OSRM](https://project-osrm.org) (BSD), car profile | fare estimates, ETAs, distances, God View "follow roads" |
| Search | [Photon](https://github.com/komoot/photon) (Apache 2.0) | search boxes, the address under the pin |
| Web map | [Protomaps](https://protomaps.com) vector tiles (BSD; data ODbL) served by go-pmtiles | the map in the web app (MapLibre); phones and desktop keep their own |

The data is © OpenStreetMap contributors (ODbL). The web map shows that
credit.

## How it fits together

```
 geo function ──https──► maps.getride.my  ─┐                  ┌─► osrm    (routes)
 (Supabase)  X-Nas-Maps-Key                │  Cloudflare      │
                                           ├─ Tunnel ─► gateway (nginx) ─► photon  (search)
 web browsers ──https──► tiles.getride.my ─┘  (cloudflared)   │
             (public, cached by Cloudflare)                   └─► tiles   (go-pmtiles) + styles
 maps agent ──https──► nas-maps function: pairing, then a check-in every minute
```

- **No port is opened** on the NAS or the router. GET.ride reaches the NAS
  through a **Cloudflare Tunnel**: `cloudflared` on the NAS makes an
  outgoing connection to Cloudflare, and Cloudflare sends the two hostnames
  down it. The agent also only calls out.
- **Routes and search** (`maps.getride.my`) answer only requests that carry
  the secret header `X-Nas-Maps-Key`, and only GET.ride's `geo` function has
  the secret. You make the secret on the NAS (`MAPS_SECRET` in `.env`), and
  the agent hands it to GET.ride when it checks in, so nobody copies it into
  Admin. The gateway logs only paths and status codes: no searches, no
  places.
- **The web map** (`tiles.getride.my`) is public, like any map: the tiles are
  OpenStreetMap data. Cloudflare caches them, so the NAS's upload is spent
  on each tile only once a week. Only GET.ride's web pages may draw it
  (`TILES_ORIGINS`).
- **GET.ride keeps working when the NAS is off.** The geo function stops
  offering the NAS once it hasn't checked in for 3 minutes, and asks the next
  provider when the NAS takes longer than the wait set in Admin (1.5 s by
  default).

## What the NAS needs

- Synology DSM 7.2 or later with **Container Manager**, on an x86-64 model.
  This was planned for the **DS224+ (Celeron J4125, 18 GB)**.
- **Memory:** about 5 GB while serving. The compose file caps each part:
  OSRM 2 GB, Photon 2 GB, the rest under 1 GB. The weekly refresh needs
  about 4 GB more for an hour or two.
- **Disk:** about 20 GB: the live maps, the next week's maps while they are
  built, and the temporary search database.
- A **Cloudflare** account with the `getride.my` zone (it already is).

## 1. Get a connection code

Admin › Settings › Office NAS › Maps › **Connect the NAS** (full admins only).
Give it a name (e.g. `DS224+ office`) and **Get code**. The code
(`XXXX-XXXX`) works once, for 10 minutes. The agent uses it when it first
starts (step 5). If the code runs out, make a new one.

## 2. Make the Cloudflare Tunnel

1. [one.dash.cloudflare.com](https://one.dash.cloudflare.com) → **Zero Trust**
   → **Networks** → **Tunnels** → **Create a tunnel**.
2. Pick **Cloudflared**, name it `getride-maps`, **Save tunnel**.
3. Under **Install and run a connector**, copy the long token after
   `--token`. That is the `TUNNEL_TOKEN`. Don't run the command shown there:
   the compose file runs cloudflared for you.
4. **Public hostnames** → add two:

   | Subdomain | Domain | Service type | URL |
   |---|---|---|---|
   | `maps` | `getride.my` | HTTP | `gateway:8080` |
   | `tiles` | `getride.my` | HTTP | `gateway:8081` |

5. Optional, recommended: Cloudflare dashboard → `getride.my` → **Security**
   → **WAF** → **Rate limiting rules**. Add one rule for host
   `tiles.getride.my`, for example 600 requests a minute per IP, then block.

## 3. Put the files on the NAS

1. If **File Station** has no `docker` shared folder yet: **Control Panel** →
   **Shared Folder** → **Create**, name it `docker` on Volume 1, and give
   your account Read/Write.
2. **File Station**: make the folder `docker/nas-maps` and upload this
   folder into it, keeping its subfolders: `docker-compose.yml`,
   `.env.example`, `refresh.sh`, `agent/`, `photon/`, `gateway/`, `style/`.
   You can also upload it as a zip and use **Extract here**.
3. Over SSH, in that folder, make `.env`:

   ```sh
   cd /volume1/docker/nas-maps
   cp .env.example .env
   openssl rand -hex 32                  # copy the output: MAPS_SECRET
   vi .env                               # or the DSM Text Editor
   ```

   Fill in `PAIR_CODE` (step 1), `TUNNEL_TOKEN` (step 2) and
   `MAPS_SECRET`. `GETRIDE_URL`, `MAPS_URL` and `TILES_URL` are already
   right for getride.my.

## 4. Build, and make the first maps (SSH)

In `/volume1/docker/nas-maps`:

```sh
sudo docker compose build                 # the agent and Photon, about 5 minutes
mkdir -p agent-data maps/status           # where the agent keeps its key; the refresh's status
sudo chown "$(sudo docker run --rm --entrypoint id getride-nas-maps-agent:1 -u)" agent-data
chmod 700 agent-data
sudo sh refresh.sh                        # the first maps: 2 to 3 hours on the DS224+
```

`refresh.sh` downloads the OpenStreetMap extract and builds the routes
(OSRM), then the search. For the search it imports the extract into a
temporary Nominatim database, Photon reads that database, and the temporary
database is deleted. Then it cuts the region out of the latest Protomaps
build and makes the map styles. Last, it starts everything with
`docker compose up -d`. You can leave the SSH session open, or run it as a
one-off task in Task Scheduler instead. If `docker compose` isn't found, use
`docker-compose`.

## 5. Check it

```sh
sudo docker compose ps                    # six containers, running
sudo docker logs -f maps-agent
```

1. The agent's log shows `Connected as …` (**Ctrl+C** stops watching).
   Admin › Settings › Office NAS › Maps now shows **Working**, with routes,
   search, the web map and the tunnel all ticked.
2. Remove the code from `.env`, because it only works once:
   `sed -i 's/^PAIR_CODE=.*/PAIR_CODE=/' .env`
3. Admin › Maps: put **Office NAS (OpenStreetMap)** first in Routes,
   Distances, Place search and Address lookup, with Google after it. For
   the web, also pick it for Map and Map (dark mode). Use **Test** there to
   see it answer.

If the code ran out before the maps were built, make a new one, put it in
`.env`, and run `sudo docker compose up -d --force-recreate agent`.

## The weekly refresh

DSM → **Control Panel** → **Task Scheduler** → **Create** → **Scheduled
Task** → **User-defined script**:

- **General:** name `Maps refresh`, user `root`.
- **Schedule:** weekly, Monday at 03:00. A night time is best: the NAS
  works hard for an hour or two.
- **Task Settings:** run `sh /volume1/docker/nas-maps/refresh.sh`. Tick
  "Send run details by email" if you want the log.

Each stage builds into `maps/next` while the current maps keep serving. Only
the last step stops the maps, for about a minute, to swap the new data in.
GET.ride asks the next provider meanwhile. If a stage fails, the old maps
stay live and Admin shows the stage and the error. Admin also shows the
stage and progress while the refresh runs, and the date of the OpenStreetMap
data in use.

## Updating

Upload the new files over the old ones, then
`sudo docker compose build && sudo docker compose up -d`. The agent's key in
`agent-data/` is kept, so it stays connected. The maps in `maps/` are kept
too.

## If something is wrong

| You see | Do this |
|---|---|
| Admin: **Not connected** / log `Not connected. Make a code …` | Put a fresh `PAIR_CODE` in `.env`, then `sudo docker compose up -d --force-recreate agent`. |
| log `Pairing refused … wrong or has expired` | The code works once, for 10 minutes: make a new one. |
| log `This NAS was disconnected in Admin` | It was removed in Admin: make a new code and put it in `.env`. |
| log `Can't save to /data …` | Run the `mkdir`, `chown` and `chmod` lines of step 4, then restart the agent. |
| Admin: the tunnel is red, the rest green | Check the tunnel is **Healthy** in Cloudflare and that both hostnames point to `gateway:8080` / `gateway:8081`. Run `sudo docker logs maps-tunnel`. |
| Admin: "has not told GET.ride its tunnel address and secret" | Set `MAPS_URL` and `MAPS_SECRET` (at least 32 characters) in `.env`, then recreate the agent. |
| Admin: routes or search red after a refresh | `sudo docker logs maps-osrm` / `maps-photon`. Running `sudo sh refresh.sh` again rebuilds everything. |
| The refresh failed at `search` | `docker logs` of the Nominatim import is printed in the refresh's log. It needs about 4 GB free memory and 15 GB free disk. |
| The web map is blank, the app shows its own | Open `https://tiles.getride.my/styles/light.json` in a browser: it should be JSON. If it is, check `TILES_ORIGINS` covers the web app's address. |

Admin shows the NAS **Offline** when it hasn't checked in for 3 minutes.

## Files

| File | What it is |
|---|---|
| `docker-compose.yml` | OSRM, Photon, go-pmtiles, the nginx gateway, cloudflared and the agent, with their memory caps |
| `.env.example` | What `.env` needs |
| `gateway/nginx.conf.template` | The gateway: the secret check for routes and search, the public map with its cache headers and CORS |
| `refresh.sh` | The weekly refresh (run as root from Task Scheduler) |
| `style/make_style.mjs` | Makes the light and dark map styles from `@protomaps/basemaps` |
| `agent/` | The maps agent: pairing, and the check-in every minute (`pytest deploy/nas-maps/agent/test_core.py`) |
| `photon/Dockerfile` | Photon on Java 21 |
