// GET.ride in-browser face check (migration 0320): the last fallback of the
// face match order (AWS, then the office NAS, then here). It runs only in
// the admin web app, while an admin has Documents > Sign-in checks open:
// the selfie and the ID photo are compared in this page and dropped; only
// the score is saved. A score helps the admin decide: nothing is approved
// or rejected by it.
//
// vladmandic/human (MIT, https://github.com/vladmandic/human), pinned. Its
// face models (about 9 MB: face finder, face mesh, face description) are downloaded once
// per browser from the same pinned version and kept by the browser's cache.
const HUMAN_VERSION = '3.3.6';
const BASE = `https://cdn.jsdelivr.net/npm/@vladmandic/human@${HUMAN_VERSION}`;

let ready = null;

function load() {
  ready ??= (async () => {
    const { Human } = await import(`${BASE}/dist/human.esm.js`);
    const human = new Human({
      modelBasePath: `${BASE}/models/`,
      backend: 'webgl',
      debug: false,
      cacheSensitivity: 0,
      filter: { enabled: true, equalization: false },
      face: {
        enabled: true,
        detector: { rotation: true, maxDetected: 1, return: false },
        mesh: { enabled: true },
        iris: { enabled: false },
        description: { enabled: true },
        emotion: { enabled: false },
        antispoof: { enabled: false },
        liveness: { enabled: false },
      },
      body: { enabled: false },
      hand: { enabled: false },
      object: { enabled: false },
      gesture: { enabled: false },
      segmentation: { enabled: false },
    });
    await human.load();
    return human;
  })().catch((e) => {
    ready = null;
    throw e;
  });
  return ready;
}

// The face's description (embedding) in the photo at [url], or null.
async function embedding(human, url) {
  const res = await fetch(url, { mode: 'cors', credentials: 'omit', cache: 'no-store' });
  if (!res.ok) throw new Error('photo');
  const bitmap = await createImageBitmap(await res.blob());
  try {
    const out = await human.detect(bitmap);
    const faces = (out.face || []).filter((f) => Array.isArray(f.embedding) && f.embedding.length > 0);
    faces.sort((a, b) => b.box[2] * b.box[3] - a.box[2] * a.box[3]);
    return faces.length ? faces[0].embedding : null;
  } finally {
    if (bitmap.close) bitmap.close();
  }
}

// { state: 'match' | 'no_match' | 'no_face', score?: 0..100 }. Throws when
// the library or a photo can't be loaded.
export async function compare(selfieUrl, cardUrl) {
  const human = await load();
  const a = await embedding(human, selfieUrl);
  const b = await embedding(human, cardUrl);
  if (!a || !b) return { state: 'no_face' };
  // human's similarity: 0..1, above 0.5 the same person.
  const score = Math.round(human.match.similarity(a, b) * 10000) / 100;
  return { state: score >= 50 ? 'match' : 'no_match', score };
}
