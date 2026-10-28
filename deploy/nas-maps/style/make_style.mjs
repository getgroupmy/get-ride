// Makes the MapLibre styles the web app draws the NAS's map with (see
// ../README.md): styles/light.json and styles/dark.json, from Protomaps'
// own basemap layers, pointing at this NAS's tiles, fonts and icons.
//
//   TILES_URL=https://tiles.getride.my node make_style.mjs <out dir>
//
// refresh.sh runs it in a Node container with @protomaps/basemaps installed
// next to it (the version must match the tiles' build: v4 and later).
import { layers, namedFlavor } from "@protomaps/basemaps";
import { mkdirSync, writeFileSync } from "node:fs";

export const ATTRIBUTION =
  '<a href="https://www.openstreetmap.org/copyright">© OpenStreetMap contributors</a>, ' +
  '<a href="https://protomaps.com">Protomaps</a>';

export function style(base, slot, lang = "en") {
  return {
    version: 8,
    name: `GET.ride ${slot}`,
    glyphs: `${base}/fonts/{fontstack}/{range}.pbf`,
    sprite: `${base}/sprites/v4/${slot}`,
    sources: {
      protomaps: { type: "vector", url: `${base}/basemap.json`, attribution: ATTRIBUTION },
    },
    layers: layers("protomaps", namedFlavor(slot), { lang }),
  };
}

const base = (process.env.TILES_URL || "").trim().replace(/\/+$/, "");
const out = process.argv[2];
if (!/^https:\/\/[A-Za-z0-9.-]+(:\d{1,5})?$/.test(base) || !out) {
  console.error("Usage: TILES_URL=https://tiles.example.com node make_style.mjs <out dir>");
  process.exit(2);
}
mkdirSync(out, { recursive: true });
for (const slot of ["light", "dark"]) {
  const s = style(base, slot, process.env.STYLE_LANG || "en");
  writeFileSync(`${out}/${slot}.json`, JSON.stringify(s));
  console.log(`${slot}.json: ${s.layers.length} layers`);
}
