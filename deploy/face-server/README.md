# Face match server

A small server that says how alike the face on a selfie is to the face on an
ID photo. Admin → Documents → Sign-in checks uses it (through the
`face-compare` edge function) when Admin → Dispatch → Accounts → **Face match**
is **Self-hosted server** or **Self-hosted, then AWS**. It costs nothing per
check, unlike AWS Rekognition.

The score only helps the admin. Nothing is approved on it.

- Python, FastAPI and [DeepFace](https://github.com/serengil/deepface) with
  the **SFace** model (Apache 2.0). **Dlib** (Boost licence) is optional.
  VGG-Face, ArcFace, Facenet and the other DeepFace models are not allowed:
  their weights are for non-commercial use only.
- `GET /health`: `{"status": "ok", "model": "SFace"}`. With an `x-api-key`
  header it also checks the key (401 when it is wrong). Admin → API Keys →
  Test uses this.
- `POST /compare` with `x-api-key: FACE_API_KEY` and
  `{"image1": "<base64>", "image2": "<base64>"}` →
  `{"similarity": 0.82, "model": "SFace", "verified": true}`. On this scale
  0.8 is the model's own threshold for "same person". `422 {"error": "no_face"}`
  when a photo has no face; `413` over the size limit (6 MB a photo); `401` for
  a wrong key.
- The key is compared in constant time. The photos are decoded in memory,
  compared and dropped: nothing is written to disk or logged.
- Reached only through a Cloudflare Tunnel: no port is opened on the NAS or
  the router.

## What the NAS needs

- Synology DSM 7.2 or later with **Container Manager** (Package Center).
- An x86-64 CPU **with AVX**: DeepFace loads TensorFlow, which needs it. AMD
  Ryzen models (DS923+, DS1522+, DS1621+) have it. Many Celeron models
  (DS920+, DS720+, J4125) do not. To check, turn on SSH (Control Panel →
  Terminal & SNMP), sign in and run `grep -c avx /proc/cpuinfo`: more than 0
  is fine.
- 2 GB of free memory and about 3 GB of disk.

## 1. Make the secret key

On any computer: `openssl rand -hex 32`. Keep the result: it is the
`FACE_API_KEY` here and goes into Admin → API Keys later. Don't put it in
chat, email or git.

## 2. Make the Cloudflare Tunnel

1. [one.dash.cloudflare.com](https://one.dash.cloudflare.com) → **Zero Trust**
   → **Networks** → **Tunnels** → **Create a tunnel**.
2. Pick **Cloudflared**, name it `getride-face`, **Save tunnel**.
3. On "Install and run a connector", pick **Docker**. The command shown ends
   in `--token eyJ...`: copy that token (only the part after `--token`). It
   is the `TUNNEL_TOKEN`. Don't run the command: the compose file runs
   cloudflared for you.
4. **Next** → **Public Hostname**: subdomain `face`, domain `getride.my`,
   path empty, service type **HTTP**, URL `face-server:8000`. **Save tunnel**.

The tunnel shows **Healthy** once the containers are up (step 3).

## 3. Run it in Container Manager

1. **File Station**: make the folder `docker/face-server` and upload this
   folder's files into it (`Dockerfile`, `docker-compose.yml`, `app.py`,
   `core.py`, `requirements.txt`, `.env.example`).
2. Copy `.env.example` to `.env` in the same folder (File Station → right
   click → Copy, then rename; or make it in a text editor) and fill in
   `FACE_API_KEY` and `TUNNEL_TOKEN`.
3. **Container Manager** → **Project** → **Create**:
   - Project name: `face-server`
   - Path: `docker/face-server`
   - Source: **Use existing docker-compose.yml** (or **Create
     docker-compose.yml** and paste this folder's `docker-compose.yml`).
   - **Next** → leave Web Station off → **Done**.

   The first build takes 10 to 20 minutes (it downloads TensorFlow and the
   SFace weights). The project then shows both containers, `face-server` and
   `face-tunnel`, running.
4. Check it: open `https://face.getride.my/health` in a browser. It shows
   `{"status":"ok","model":"SFace"}`.

To use Dlib instead, set `FACE_MODEL=Dlib` and `WITH_DLIB=1` in `.env`, then
in the project **Action** → **Build** (compiling dlib adds about 20 minutes).

To update after a change here: upload the files again, then **Action** →
**Build**, then **Start**.

## 4. Put it into get.ride

1. Admin → Settings → **API Keys** → **Face match server** → **Self-hosted
   server** → **Add key**. Value:
   `https://face.getride.my:` followed by the `FACE_API_KEY`, for example
   `https://face.getride.my:3f9c...e1`. (A space instead of the colon works
   too.)
2. **Test** → **Face match server · health**. "Works" means the server is up
   and takes the key.
3. Admin → **Dispatch** → **Accounts** → **Face match**: pick **Self-hosted
   server**, or **Self-hosted, then AWS** to fall back to AWS Rekognition when
   the NAS is off (needs the AWS key too).
4. Admin → Documents → **Sign-in checks** → an upload → **Compare selfie
   with ID** shows e.g. "82% match · self-hosted".

## Tests

`pytest deploy/face-server/test_core.py` checks the key check, the size
limit and the similarity scale without DeepFace.
