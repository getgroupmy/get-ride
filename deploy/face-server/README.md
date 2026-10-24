# Face match server

A small server that says how alike the face on a selfie is to the face on an
ID photo. Admin → Documents → Sign-in checks uses it (through the
`face-compare` edge function) when Admin → Dispatch → Accounts → **Face match**
is **Self-hosted server** or **Self-hosted, then AWS**. It costs nothing per
check, unlike AWS Rekognition.

The score only helps the admin. Nothing is approved on it.

- Python, FastAPI and OpenCV only (`opencv-python-headless`; no TensorFlow,
  no DeepFace, no onnxruntime). Two models from
  [opencv_zoo](https://github.com/opencv/opencv_zoo), both Apache 2.0, run by
  OpenCV's own `cv2.dnn`: **YuNet** finds the face (`cv2.FaceDetectorYN`,
  `face_detection_yunet_2023mar.onnx`) and **SFace** compares them
  (`cv2.FaceRecognizerSF`, `face_recognition_sface_2021dec.onnx`). The image
  build fetches both from a fixed opencv_zoo commit and stops if either's
  sha256 differs (`fetch_models.py`).
- `GET /health`: `{"status": "ok", "model": "SFace"}`. With an `x-api-key`
  header it also checks the key (401 when it is wrong). Admin → API Keys →
  Test uses this.
- `POST /compare` with `x-api-key: FACE_API_KEY` and
  `{"image1": "<base64>", "image2": "<base64>"}` →
  `{"similarity": 0.87, "model": "SFace", "verified": true, "cosine": 0.6}`.
  `422 {"error": "no_face"}` when a photo has no face (an answer, not a
  failure: get.ride doesn't then ask AWS); `413` over the size limit (6 MB a
  photo); `400` for something that isn't a photo; `401` for a wrong key. On an
  ID photo the biggest face is used (the main photo, not a MyKad's small ghost
  picture).
- **The similarity scale.** SFace gives a cosine score from -1 to 1
  (`FaceRecognizerSF.match` with `FR_COSINE`); OpenCV suggests 0.363 or more
  for the same person. `similarity` puts that on 0 to 1 with 0.363 at 0.8, the
  point get.ride reads as "match": from 0.363 to 1 it runs straight from 0.8 to
  1.0, from 0 to 0.363 straight from 0 to 0.8, and below 0 it is 0. So a cosine
  of 0.6 shows as 87%, 0.2 as 44%. `verified` is cosine ≥ 0.363; `cosine` is the
  raw score. (`core.similarity`, tested in `test_core.py`.)
- The key is compared in constant time. The photos are decoded in memory,
  compared and dropped: nothing is written to disk or logged.
- Reached only through a Cloudflare Tunnel: no port is opened on the NAS or
  the router.

## What the NAS needs

- Synology DSM 7.2 or later with **Container Manager** (Package Center), on an
  x86-64 model. It runs on the **DS224+ (Intel Celeron J4125)**: that CPU has
  no AVX, and nothing here needs it (OpenCV's and NumPy's wheels are built for
  SSE3 and only use AVX where the CPU has it).
- About 420 MB of disk for the image and about 200 MB of memory while it runs
  (the compose file caps it at 512 MB). A check takes well under a second.

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
   `core.py`, `fetch_models.py`, `requirements.txt`, `.env.example`).
2. Copy `.env.example` to `.env` in the same folder (File Station → right
   click → Copy, then rename; or make it in a text editor) and fill in
   `FACE_API_KEY` and `TUNNEL_TOKEN`.
3. **Container Manager** → **Project** → **Create**:
   - Project name: `face-server`
   - Path: `docker/face-server`
   - Source: **Use existing docker-compose.yml** (or **Create
     docker-compose.yml** and paste this folder's `docker-compose.yml`).
   - **Next** → leave Web Station off → **Done**.

   The first build takes a few minutes (it downloads OpenCV and the two
   models). The project then shows both containers, `face-server` and
   `face-tunnel`, running.
4. Check it: open `https://face.getride.my/health` in a browser. It shows
   `{"status":"ok","model":"SFace"}`.

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
   with ID** shows e.g. "87% match · self-hosted".

## Tests

`pytest deploy/face-server/test_core.py` checks the key check, the size
limit and the similarity scale without OpenCV or the models.
