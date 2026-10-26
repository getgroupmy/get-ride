# Document reader (office NAS)

Reads plates, document numbers and QR codes off the document photos partners
and vehicles upload, in the background, on the office NAS. Admin → Settings →
Document reading shows it, its work today, and what it reads; a reading it is
less sure of than the "pass on" percentage goes to the next reader in the
order (the cloud reader).

- PP-OCR ([RapidOCR](https://github.com/RapidAI/RapidOCR), Apache 2.0) through
  Intel OpenVINO on the processor. It runs on the **DS224+ (Celeron J4125)**,
  which has no AVX; measured there at about **1.2 s a plate and 2.3 s a
  document number**. The built-in graphics were slower, so they aren't used.
- It **only calls out** to GET.ride (the `doc-reader` edge function): no port
  is opened on the NAS or the router, and no tunnel is needed.
- It pairs once with a code from Admin and keeps its own key in `data/key.json`
  (only a hash of it is on the server). Disconnecting it in Admin ends the key.
- Each photo comes as a 5-minute link, is read in memory and dropped. Only the
  plates, numbers and QR codes GET.ride asked for are sent back, never the
  other text on the document (names, addresses). The log has counts and
  timings only.

## What the NAS needs

- Synology DSM 7.2 or later with **Container Manager**, on an x86-64 model.
- About 1.2 GB of disk for the image and up to 1 GB of memory while reading
  (the compose file caps it at 1 GB).

## 1. Get a connection code

Admin → Settings → Document reading → **Office NAS** → **Connect a NAS**
(full admins only). Give it a name (e.g. `DS224+ office`) and **Get code**.
The code (`XXXX-XXXX`) works once, for 10 minutes, and is used when the
reader first starts (step 3): if it runs out, make a new one.

## 2. Put the files on the NAS

1. If **File Station** has no `docker` shared folder yet: **Control Panel** →
   **Shared Folder** → **Create**, name `docker` on Volume 1, and give your
   account Read/Write.
2. **File Station**: make the folder `docker/doc-reader` and upload this
   folder's files into it: `Dockerfile`, `docker-compose.yml`, `core.py`,
   `reader.py`, `requirements.txt`, `.env.example` (or upload them as a zip
   and **Extract here**).
3. Over SSH, in that folder, put the code from step 1 in `.env`:

   ```sh
   cd /volume1/docker/doc-reader
   cp .env.example .env
   sed -i 's/^PAIR_CODE=.*/PAIR_CODE=ABCD-2345/' .env   # your code
   ```

   `GETRIDE_URL` is already your backend's.

The `data` folder the reader keeps its key in is made in step 3 below:
Synology's Docker doesn't make it, and the container won't start without it.

## 3. Build and start it (SSH)

In `/volume1/docker/doc-reader`:

```sh
sudo docker compose build          # about 400 MB, 5 to 10 minutes on the DS224+
mkdir -p data                      # where the reader keeps its key
sudo chown "$(sudo docker run --rm getride-doc-reader:1 id -u)" data
chmod 700 data
sudo docker compose up -d
sudo docker logs -f doc-reader
```

The reader runs as its own user, not root, so `data` is given to that user.
If `docker compose` isn't found, use `docker-compose`.

1. The log shows `Connected as …` (**Ctrl+C** stops watching; the reader
   keeps running). The NAS now shows **Online** in Admin → Settings →
   Document reading.
2. Remove the code from `.env` (it is used once):
   `sed -i 's/^PAIR_CODE=.*/PAIR_CODE=/' .env`

If the build took longer than the code's 10 minutes, make a new one, put it
in `.env` as above and run `sudo docker compose up -d --force-recreate`.

Container Manager (**Project** → **Create**, path `docker/doc-reader`,
**Use existing docker-compose.yml**) also runs it, once `data` is made as
above.

## Updating

Upload the new files over the old ones and, in Container Manager, **Project**
→ `doc-reader` → **Action** → **Build**. The key in `data/` is kept, so it
stays connected.

## If something is wrong

| The log says | Do this |
|---|---|
| `Bind mount failed: '…/doc-reader/data' does not exist` (when starting) | Make `data` as in step 3, then `sudo docker compose up -d`. |
| `Can't save to /data …` | `data` isn't the reader's: run the `chown` and `chmod` lines of step 3, then restart. |
| `Not connected. Make a code …` | Put a fresh `PAIR_CODE` in `.env` and restart the project. |
| `Pairing refused … wrong or has expired` | The code is single-use and lasts 10 minutes: make a new one. |
| `This reader was disconnected in Admin` | It was removed in Admin: make a new code and put it in `.env`. |
| `GET.ride can't be reached` | Check the NAS's internet connection; it retries every minute. |

Admin shows it **Offline** when it hasn't checked in for 3 minutes.

## Tests

`pytest deploy/doc-reader/test_core.py` checks what is pulled out of the
OCR's text (plates, MyKad and chassis numbers, cover note and permit numbers,
QR codes) and that nothing else is sent, without the OCR.
