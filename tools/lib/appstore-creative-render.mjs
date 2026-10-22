// D-077: the appstore-creative render extension. It drives the pinned Goldie 0.3.1 through its
// published modules and adds, inside this process only, what Goldie lacks: a `concept` layout that
// draws copy and image layers with no device, an iPhone 6.3-inch device (1206x2622, D-079), an iPad
// 13-inch device (2064x2752, bare screen), and
// background images under the copy (Goldie draws its image layers over the headline). Goldie's own
// layouts render exactly as before when a config uses none of these, and the installed runtime is
// never written to.
//
// D-085 (#394) adds, drawn with the runtime's own @napi-rs/canvas after Goldie renders: image layers in
// front of or behind the device that may run into the next tile within a limit, popouts that magnify
// a region of the real capture, a bare or cropped screen in place of the device, stories that split
// one sentence across tiles, and a mark for tiles with more visual layers than the guide.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

export const GOLDIE_VERSION = "0.3.1";
export const IPHONE_KEY = "iphone-6.3";
export const IPAD_KEY = "ipad-13";
export const IPAD = { width: 2064, height: 2752, previewWidth: 1200, previewHeight: 1600, screenRadius: 54 };

export const CONCEPT_LAYOUT = {
  key: "concept",
  label: "Concept",
  description: "Copy over the background and image layers, with no device.",
  span: 1,
  copy: { position: "top", align: "center", heightRatio: 0.24 },
  devices: []
};

// D-079: App Store iPhone screenshots are Dynamic Island (medium display), 1206x2622. Goldie 0.3.1 only
// ships iphone-6.9 (1320x2868), but its iOS bezel is already the iPhone 17 Pro artwork and its screen
// (557x1210) has the same aspect ratio to within 0.1%, so the iOS path draws this device unchanged.
export const IPHONE_DEVICE = {
  label: "6.3",
  platform: "ios",
  simulatorName: "iPhone 17 Pro",
  native: { width: 1206, height: 2622 },
  screenshot: { width: 1206, height: 2622 },
  preview: { width: 886, height: 1920 }
};

// Goldie 0.3.1 picks iOS bezel geometry from a fixed iPhone table and takes custom geometry only from
// the config's android.frame. The iPad entry therefore uses that path with a bare screen: the bezel
// image is never loaded, and the screen keeps the iPad capture's own aspect ratio, so no capture pixel
// is cropped away.
export const IPAD_DEVICE = {
  label: IPAD_KEY,
  platform: "android",
  native: { width: IPAD.width, height: IPAD.height },
  screenshot: { width: IPAD.width, height: IPAD.height },
  preview: { width: IPAD.previewWidth, height: IPAD.previewHeight },
  screenOnly: true
};

class Failure extends Error {}

function fail(message) {
  throw new Failure(message);
}

export function defaultRuntime(env = process.env) {
  const cache = env.XDG_CACHE_HOME && isAbsolute(env.XDG_CACHE_HOME) ? env.XDG_CACHE_HOME : join(homedir(), ".cache");
  return join(cache, "codex-goldie", GOLDIE_VERSION);
}

export async function loadGoldie(runtime) {
  const packagePath = join(runtime, "node_modules", "goldie", "package.json");
  if (!existsSync(packagePath)) fail(`Goldie runtime not found: ${runtime}`);
  const version = JSON.parse(readFileSync(packagePath, "utf8")).version;
  if (version !== GOLDIE_VERSION) fail(`Goldie runtime must be ${GOLDIE_VERSION}, found ${version}`);
  const goldie = await import(pathToFileURL(join(runtime, "node_modules", "goldie", "dist", "index.js")).href);
  return { goldie, version, root: join(runtime, "node_modules", "goldie") };
}

export function extend(goldie) {
  if (!goldie.LAYOUT_KEYS.includes(CONCEPT_LAYOUT.key)) goldie.LAYOUT_KEYS.push(CONCEPT_LAYOUT.key);
  goldie.LAYOUTS[CONCEPT_LAYOUT.key] = structuredClone(CONCEPT_LAYOUT);
  goldie.DEVICES[IPHONE_KEY] = structuredClone(IPHONE_DEVICE);
  goldie.DEVICES[IPAD_KEY] = structuredClone(IPAD_DEVICE);
}

function ipadFrame(goldieRoot) {
  // Any existing PNG satisfies Goldie's file check; screenOnly means it is never read.
  return {
    image: join(goldieRoot, "assets", "17-pro-silver.png"),
    width: IPAD.width,
    height: IPAD.height,
    screen: { x: 0, y: 0, width: IPAD.width, height: IPAD.height },
    screenRadius: IPAD.screenRadius
  };
}

function sha256(path) {
  return `sha256:${createHash("sha256").update(readFileSync(path)).digest("hex")}`;
}

function pngSize(path) {
  const bytes = readFileSync(path);
  if (bytes.subarray(0, 8).toString("hex") !== "89504e470d0a1a0a") fail(`not a PNG: ${path}`);
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20), colorType: bytes[25] };
}

// A screenshot scene, or the theme for every scene, may name `backgroundImage`: a path relative to the
// config, or { src, strip, index } for one image that runs through `strip` tiles, of which this scene
// starts at zero-based `index`. Goldie renders those scenes on a transparent background, and the
// image is then placed under them, scaled to cover and cropped to each tile.
export function backgroundPlan(cfg) {
  const scenes = cfg.scenes.filter((scene) => scene.kind === "screenshot");
  const ids = new Set(scenes.map((scene) => scene.id));
  for (const id of ids) {
    if (/-\d+$/.test(id) && ids.has(id.replace(/-\d+$/, ""))) fail(`scene id ${id} is ambiguous next to ${id.replace(/-\d+$/, "")}`);
  }
  const plan = new Map();
  for (const scene of scenes) {
    const value = scene.backgroundImage ?? cfg.theme.backgroundImage;
    if (value === undefined) continue;
    const entry = typeof value === "string" ? { src: value } : value;
    if (!entry || typeof entry.src !== "string" || !entry.src) fail(`backgroundImage of ${scene.id} needs src`);
    const unknown = Object.keys(entry).filter((key) => !["src", "strip", "index"].includes(key));
    if (unknown.length) fail(`backgroundImage of ${scene.id} has unknown field ${unknown[0]}`);
    const strip = entry.strip ?? null;
    const index = entry.index ?? 0;
    if (strip !== null && !(Number.isInteger(strip) && strip >= 1)) fail(`backgroundImage strip of ${scene.id} must be a positive integer`);
    if (!(Number.isInteger(index) && index >= 0)) fail(`backgroundImage index of ${scene.id} must be a non-negative integer`);
    const src = resolve(cfg.root, entry.src);
    if (!existsSync(src)) fail(`background image not found: ${src}`);
    plan.set(scene.id, { src, strip, index });
    scene.background = "transparent";
  }
  return plan;
}

// --- D-085 creative additions ----------------------------------------------------------------------

export const CROSS_TILE_DEFAULTS = { max: 0.3, abstractMax: 0.4, protectedRoles: ["headline", "app-name", "face", "key-number", "claim"] };
export const LAYER_LIMIT_DEFAULT = 4;
const ABSTRACT_ROLES = ["background", "abstract"];
const FRAMES = ["device", "bare", "crop"];
const HEX = /^#[0-9A-Fa-f]{6}$/;

function number(value, label, { min = -Infinity, max = Infinity } = {}) {
  if (typeof value !== "number" || !Number.isFinite(value) || value < min || value > max) fail(`${label} must be a number from ${min} to ${max}`);
  return value;
}

function region(value, label) {
  if (!value || typeof value !== "object") fail(`${label} needs a region { x, y, width, height } in capture pixels`);
  for (const key of ["x", "y", "width", "height"]) {
    if (!Number.isInteger(value[key]) || value[key] < 0) fail(`${label} region ${key} must be a non-negative integer`);
  }
  if (value.width === 0 || value.height === 0) fail(`${label} region must not be empty`);
  return { x: value.x, y: value.y, width: value.width, height: value.height };
}

function placement(value, label, defaults) {
  const entry = { ...defaults, ...(value ?? {}) };
  number(entry.width, `${label} width`, { min: 0.01, max: 3 });
  number(entry.x, `${label} x`, { min: -2, max: 3 });
  number(entry.y, `${label} y`, { min: -2, max: 3 });
  return entry;
}

function captureFile(cfg, device, scene, captures) {
  if (!captures.manifest) {
    const path = join(cfg.outDir, "raw", device, "manifest.json");
    if (!existsSync(path)) fail(`raw capture manifest not found: ${path}`);
    captures.manifest = JSON.parse(readFileSync(path, "utf8"));
    captures.path = path;
  }
  const entry = (captures.manifest.screenshots ?? []).find((item) => item.sceneId === scene.id);
  if (!entry || typeof entry.file !== "string") fail(`${scene.id} has no capture in ${captures.path}`);
  const file = resolve(dirname(captures.path), entry.file);
  if (!existsSync(file)) fail(`capture of ${scene.id} not found: ${file}`);
  return file;
}

// Stories set the headline of consecutive scenes from one sentence, split at character positions.
function applyStories(cfg, locale) {
  const stories = cfg.theme.stories ?? [];
  if (!Array.isArray(stories)) fail("theme.stories must be a list");
  const order = cfg.scenes.filter((scene) => scene.kind === "screenshot").map((scene) => scene.id);
  return stories.map((story, index) => {
    const label = `story ${index + 1}`;
    const scenes = story?.scenes;
    if (!Array.isArray(scenes) || scenes.length < 2) fail(`${label} needs two or more scenes`);
    const start = order.indexOf(scenes[0]);
    if (start < 0 || scenes.some((id, offset) => order[start + offset] !== id)) fail(`${label} scenes must be consecutive screenshot scenes in order`);
    const text = story.text?.[locale];
    if (typeof text !== "string" || !text.trim()) fail(`${label} has no text for ${locale}`);
    const breaks = story.breaks?.[locale] ?? [];
    if (!Array.isArray(breaks) || breaks.length !== scenes.length - 1) {
      fail(`${label} needs ${scenes.length - 1} break${scenes.length === 2 ? "" : "s"} for ${scenes.length} scenes in ${locale}; found ${Array.isArray(breaks) ? breaks.length : 0}`);
    }
    const chars = Array.from(text);
    const cuts = [0, ...breaks, chars.length];
    for (let i = 1; i < cuts.length; i += 1) {
      if (!Number.isInteger(cuts[i]) || cuts[i] <= cuts[i - 1]) fail(`${label} breaks for ${locale} must increase inside the text`);
    }
    const ellipsis = story.ellipsis ?? true;
    const parts = scenes.map((_, i) => {
      let part = chars.slice(cuts[i], cuts[i + 1]).join("").trim();
      if (!part) fail(`${label} part ${i + 1} is empty`);
      if (ellipsis && i > 0) part = `…${part}`;
      if (ellipsis && i < scenes.length - 1) part = `${part}…`;
      return part;
    });
    scenes.forEach((id, i) => {
      const scene = cfg.scenes.find((item) => item.id === id);
      scene.headline = { ...(scene.headline ?? {}), [locale]: parts[i] };
    });
    return { scenes, parts: { [locale]: parts } };
  });
}

// Validates layers, popouts and frames, switches bare and cropped screens to the device-free concept
// layout, and renders scenes with a back layer on a transparent background so the tool can paint the
// background, the back layers and then Goldie's device and copy in that order.
export function creativePlan(cfg, device, backgrounds, tile, spanOf) {
  const configured = cfg.theme.crossTile ?? {};
  const added = configured.protectedRoles ?? [];
  if (!Array.isArray(added) || added.some((role) => typeof role !== "string")) fail("theme.crossTile.protectedRoles must be a list of roles");
  // The default protected roles are mandatory; a config may only add to them.
  const crossTile = { ...CROSS_TILE_DEFAULTS, ...configured,
    protectedRoles: [...new Set([...CROSS_TILE_DEFAULTS.protectedRoles, ...added])] };
  number(crossTile.max, "theme.crossTile.max", { min: 0, max: 1 });
  number(crossTile.abstractMax, "theme.crossTile.abstractMax", { min: 0, max: 1 });
  const layerLimit = cfg.theme.layerLimit ?? LAYER_LIMIT_DEFAULT;
  if (!Number.isInteger(layerLimit) || layerLimit < 1) fail("theme.layerLimit must be a positive integer");
  const scenes = new Map();
  const captures = {};
  for (const scene of cfg.scenes.filter((item) => item.kind === "screenshot")) {
    const frame = scene.frame ?? "device";
    if (!FRAMES.includes(frame)) fail(`frame of ${scene.id} must be device, bare or crop`);
    const layers = (scene.layers ?? []).map((layer, index) => {
      const label = `layer ${index + 1} of ${scene.id}`;
      if (!layer || typeof layer.src !== "string" || !layer.src) fail(`${label} needs src`);
      const unknown = Object.keys(layer).filter((key) => !["src", "position", "x", "y", "width", "rotate", "shadow", "role"].includes(key));
      if (unknown.length) fail(`${label} has unknown field ${unknown[0]}`);
      const src = resolve(cfg.root, layer.src);
      if (!existsSync(src)) fail(`${label} image not found: ${src}`);
      pngSize(src);
      const position = layer.position ?? "front";
      if (!["front", "back"].includes(position)) fail(`${label} position must be front or back`);
      const place = placement(layer, label, {});
      const rotate = layer.rotate === undefined ? 0 : number(layer.rotate, `${label} rotate`, { min: -180, max: 180 });
      const role = layer.role ?? "decoration";
      if (typeof role !== "string" || !/^[a-z][a-z-]{0,31}$/.test(role)) fail(`${label} role must be lowercase letters and hyphens`);
      return { index: index + 1, src, position, x: place.x, y: place.y, width: place.width, rotate, shadow: layer.shadow === true, role };
    });
    const concept = (scene.layout ?? cfg.theme.layout) === CONCEPT_LAYOUT.key;
    let screen = null;
    if (frame !== "device") {
      const capture = captureFile(cfg, device, scene, captures);
      const size = pngSize(capture);
      const area = frame === "crop" ? region(scene.crop, `crop of ${scene.id}`) : { x: 0, y: 0, width: size.width, height: size.height };
      if (area.x + area.width > size.width || area.y + area.height > size.height) {
        fail(`crop of ${scene.id} region runs outside its ${size.width}x${size.height} capture`);
      }
      const width = scene.screen?.width ?? 0.78;
      // By default the screen is centered under the copy and may run off the bottom edge.
      const place = placement(scene.screen, `screen of ${scene.id}`, { width, x: (1 - width) / 2, y: 0.27 });
      screen = { frame, capture, region: area, ...place, radius: frame === "bare" ? 0.055 : 0.03 };
      scene.layout = "concept";
    }
    const popouts = (scene.popouts ?? []).map((popout, index) => {
      const label = `popout ${index + 1} of ${scene.id}`;
      const capture = captureFile(cfg, device, scene, captures);
      const size = pngSize(capture);
      const area = region(popout?.region, label);
      if (area.x + area.width > size.width || area.y + area.height > size.height) {
        fail(`${label} region runs outside its ${size.width}x${size.height} capture`);
      }
      const place = placement(popout, label, {});
      const radius = popout.radius === undefined ? null : number(popout.radius, `${label} radius`, { min: 0, max: 400 });
      return { index: index + 1, capture, region: area, x: place.x, y: place.y, width: place.width, radius, shadow: popout.shadow !== false };
    });
    let fill = null;
    if (layers.some((layer) => layer.position === "back") && !backgrounds.has(scene.id)) {
      fill = scene.background ?? cfg.theme.background;
      if (typeof fill !== "string" || !HEX.test(fill)) fail(`a back layer on ${scene.id} needs a backgroundImage or a #RRGGBB background`);
      scene.background = "transparent";
    }
    scenes.set(scene.id, { frame, layers, screen, popouts, fill, transparent: backgrounds.has(scene.id) || fill !== null,
                           headline: Boolean(scene.headline), device: frame !== "device" || !concept });
  }
  // A back layer that runs out of its scene also sits under the neighbor's device, so the neighbor is
  // rendered transparent too and its own #RRGGBB background is painted underneath.
  const order = cfg.scenes.filter((item) => item.kind === "screenshot");
  const prepare = (neighbor, owner) => {
    const entry = scenes.get(neighbor.id);
    if (entry.transparent) return;
    const fill = neighbor.background ?? cfg.theme.background;
    if (typeof fill !== "string" || !HEX.test(fill)) {
      fail(`a back layer of ${owner.id} runs into ${neighbor.id}, which needs a backgroundImage or a #RRGGBB background`);
    }
    neighbor.background = "transparent";
    entry.fill = fill;
    entry.transparent = true;
  };
  order.forEach((scene, index) => {
    for (const layer of scenes.get(scene.id).layers.filter((item) => item.position === "back")) {
      const { bounds } = layerGeometry(layer, 1, tile);
      if (bounds.left < 0 && index > 0) prepare(order[index - 1], scene);
      if (bounds.right > spanOf(scene) * tile.width && index < order.length - 1) prepare(order[index + 1], scene);
    }
  });
  return { scenes, crossTile, layerLimit };
}

// The layer's size and position on the strip of all tiles, and the axis-aligned bounds it is drawn with
// after rotation about its center. `start` is the scene's first tile (1-based).
function layerGeometry(layer, start, tile) {
  const size = pngSize(layer.src);
  const width = layer.width * tile.width;
  const height = width * size.height / size.width;
  const left = (start - 1) * tile.width + layer.x * tile.width;
  const top = layer.y * tile.height;
  const angle = (layer.rotate * Math.PI) / 180;
  const boundsWidth = Math.abs(width * Math.cos(angle)) + Math.abs(height * Math.sin(angle));
  const center = left + width / 2;
  return { width, height, left, top, bounds: { left: center - boundsWidth / 2, right: center + boundsWidth / 2, width: boundsWidth } };
}

function tileMap(files, ids) {
  return files.map((file, position) => {
    const name = basename(file).replace(/^\d{2}-/, "").replace(/\.png$/, "");
    for (const id of ids) {
      if (name === id) return { file, scene: id, slice: 0, tile: position + 1 };
      if (name.startsWith(`${id}-`) && /^\d+$/.test(name.slice(id.length + 1))) return { file, scene: id, slice: Number(name.slice(id.length + 1)) - 1, tile: position + 1 };
    }
    fail(`cannot tell which scene rendered ${file}`);
  });
}

function roundedRect(ctx, x, y, width, height, radius) {
  const r = Math.max(0, Math.min(radius, width / 2, height / 2));
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + width, y, x + width, y + height, r);
  ctx.arcTo(x + width, y + height, x, y + height, r);
  ctx.arcTo(x, y + height, x, y, r);
  ctx.arcTo(x, y, x + width, y, r);
  ctx.closePath();
}

function shadowOn(ctx, tile) {
  ctx.shadowColor = "rgba(0, 0, 0, 0.28)";
  ctx.shadowBlur = Math.round(tile.width * 0.025);
  ctx.shadowOffsetX = 0;
  ctx.shadowOffsetY = Math.round(tile.height * 0.006);
}

async function composeCreative(canvasModule, files, plan, creative, tile, locale) {
  const { createCanvas, loadImage } = canvasModule;
  const tiles = tileMap(files, [...creative.scenes.keys()]);
  const firstTile = new Map();
  const spans = new Map();
  for (const entry of tiles) {
    if (!firstTile.has(entry.scene)) firstTile.set(entry.scene, entry.tile);
    spans.set(entry.scene, (spans.get(entry.scene) ?? 0) + 1);
  }
  // Every layer is placed on the strip of all tiles, relative to its scene's first tile.
  const layers = [];
  for (const [id, scene] of creative.scenes) {
    if (!firstTile.has(id)) continue;
    const start = firstTile.get(id);
    for (const layer of scene.layers) {
      const { width, height, left, top, bounds } = layerGeometry(layer, start, tile);
      // Every exported seam counts, including seams inside a multi-tile scene: the crossing is the
      // share of the drawn (rotated) bounds outside the one tile that holds most of the layer.
      const overlaps = tiles.map((entry) => ({ tile: entry.tile,
        share: Math.max(0, Math.min(bounds.right, entry.tile * tile.width) - Math.max(bounds.left, (entry.tile - 1) * tile.width)) / bounds.width }))
        .filter((entry) => entry.share > 1e-9);
      const touched = overlaps.map((entry) => entry.tile);
      const main = overlaps.reduce((best, entry) => (entry.share > best.share ? entry : best), { tile: start, share: 0 });
      const crossing = Math.max(0, 1 - main.share);
      const label = `layer ${layer.index} of ${id}`;
      if (crossing > 1e-9 && creative.crossTile.protectedRoles.includes(layer.role)) fail(`${label} is marked ${layer.role} and must not cross a tile seam`);
      const limit = ABSTRACT_ROLES.includes(layer.role) ? creative.crossTile.abstractMax : creative.crossTile.max;
      if (crossing > limit + 1e-9) {
        const side = touched.some((number) => number > main.tile) ? "next" : "previous";
        fail(`${label} crosses ${Math.round(crossing * 100)}% into the ${side} tile; at most ${Math.round(limit * 100)}%`);
      }
      for (const number of touched) {
        const neighbor = tiles.find((entry) => entry.tile === number);
        if (layer.position === "back" && !creative.scenes.get(neighbor.scene).transparent) {
          fail(`${label} is a back layer that runs into ${neighbor.scene}, which needs a backgroundImage or a #RRGGBB background too`);
        }
      }
      layers.push({ ...layer, scene: id, left, top, width, height, crossing, tiles: touched, image: await loadImage(layer.src) });
    }
  }
  const used = [];
  const marks = [];
  for (const entry of tiles) {
    const scene = creative.scenes.get(entry.scene);
    const here = layers.filter((layer) => layer.tiles.includes(entry.tile));
    const own = entry.slice === 0;
    const popouts = own ? scene.popouts : [];
    const screen = own ? scene.screen : null;
    const background = plan.get(entry.scene);
    const count = 1 + (scene.device ? 1 : 0) + (scene.headline ? 1 : 0) + here.length + popouts.length;
    if (count > creative.layerLimit) marks.push(`tile ${entry.tile} has ${count} visual layers; the guide is ${creative.layerLimit}`);
    if (!scene.transparent && !here.length && !popouts.length && !screen) continue;
    const canvas = createCanvas(tile.width, tile.height);
    const ctx = canvas.getContext("2d");
    const rendered = await loadImage(entry.file);
    if (scene.transparent) {
      if (background) {
        const { src, strip, index } = background;
        const tiles = strip ?? spans.get(entry.scene);
        if (index + spans.get(entry.scene) > tiles) fail(`backgroundImage of ${entry.scene} runs past its strip of ${tiles} tiles`);
        const image = await loadImage(src);
        const scale = Math.max((tiles * tile.width) / image.width, tile.height / image.height);
        const x = ((strip === null ? 0 : index) + entry.slice) * tile.width;
        const offsetX = (image.width * scale - tiles * tile.width) / 2;
        const offsetY = (image.height * scale - tile.height) / 2;
        ctx.drawImage(image, (x + offsetX) / scale, offsetY / scale, tile.width / scale, tile.height / scale, 0, 0, tile.width, tile.height);
        used.push({ file: entry.file, scene: entry.scene, source: src, sourceSha256: sha256(src), strip: tiles, tile: (strip === null ? 0 : index) + entry.slice });
      } else {
        ctx.fillStyle = scene.fill;
        ctx.fillRect(0, 0, tile.width, tile.height);
      }
    } else {
      ctx.drawImage(rendered, 0, 0);
    }
    const drawLayer = (layer) => {
      ctx.save();
      if (layer.shadow) shadowOn(ctx, tile);
      const x = layer.left - (entry.tile - 1) * tile.width;
      ctx.translate(x + layer.width / 2, layer.top + layer.height / 2);
      if (layer.rotate) ctx.rotate((layer.rotate * Math.PI) / 180);
      ctx.drawImage(layer.image, -layer.width / 2, -layer.height / 2, layer.width, layer.height);
      ctx.restore();
    };
    const drawCard = async (capture, area, place, radius, shadow) => {
      const image = await loadImage(capture);
      const width = place.width * tile.width;
      const height = width * area.height / area.width;
      const x = place.x * tile.width;
      const y = place.y * tile.height;
      ctx.save();
      if (shadow) {
        shadowOn(ctx, tile);
        roundedRect(ctx, x, y, width, height, radius);
        ctx.fillStyle = "#000000";
        ctx.fill();
        ctx.shadowColor = "rgba(0, 0, 0, 0)";
      }
      roundedRect(ctx, x, y, width, height, radius);
      ctx.clip();
      ctx.drawImage(image, area.x, area.y, area.width, area.height, x, y, width, height);
      ctx.restore();
    };
    here.filter((layer) => layer.position === "back").forEach(drawLayer);
    if (scene.transparent) ctx.drawImage(rendered, 0, 0);
    if (screen) await drawCard(screen.capture, screen.region, screen, screen.radius * screen.width * tile.width, true);
    for (const popout of popouts) {
      await drawCard(popout.capture, popout.region, popout, popout.radius ?? Math.round(tile.width * 0.02), popout.shadow);
    }
    here.filter((layer) => layer.position === "front").forEach(drawLayer);
    const rgba = join(dirname(entry.file), `.creative-${basename(entry.file)}`);
    const output = join(dirname(entry.file), `.creative-rgb-${basename(entry.file)}`);
    writeFileSync(rgba, await canvas.encode("png"));
    execFileSync("ffmpeg", ["-y", "-loglevel", "error", "-i", rgba, "-vf", "format=rgb24", "-frames:v", "1", output], { stdio: ["ignore", "ignore", "inherit"] });
    unlinkSync(rgba);
    renameSync(output, entry.file);
  }
  const record = {
    backgrounds: used,
    layers: layers.map((layer) => ({ scene: layer.scene, index: layer.index, src: layer.src, sha256: sha256(layer.src), position: layer.position,
      role: layer.role, tiles: layer.tiles, crossing: Math.round(layer.crossing * 1000) / 1000 })),
    popouts: [...creative.scenes].flatMap(([id, scene]) => scene.popouts.map((popout) => ({ scene: id, index: popout.index, capture: popout.capture,
      captureSha256: sha256(popout.capture), region: popout.region, tile: firstTile.get(id) }))),
    screens: [...creative.scenes].filter(([, scene]) => scene.screen).map(([id, scene]) => ({ scene: id, frame: scene.frame,
      capture: scene.screen.capture, captureSha256: sha256(scene.screen.capture), region: scene.screen.region })),
    marks
  };
  return record;
}

export async function render({ runtime, config, device, locale }) {
  // iphone-6.9 is Goldie's own device, kept so its output can be compared with Goldie's frame.
  if (![IPHONE_KEY, "iphone-6.9", IPAD_KEY].includes(device)) fail(`device must be ${IPHONE_KEY}, iphone-6.9 or ${IPAD_KEY}`);
  if (!["ja", "en-US"].includes(locale)) fail("locale must be ja or en-US");
  const configPath = resolve(config);
  const { goldie, version, root } = await loadGoldie(runtime);
  extend(goldie);
  const cfg = await goldie.loadConfig(configPath);
  if (!cfg.locales.includes(locale)) fail(`config ${configPath} does not list locale ${locale}`);
  if (device === IPAD_KEY) {
    cfg.android = { ...(cfg.android ?? {}), frame: ipadFrame(root) };
  }
  const plan = backgroundPlan(cfg);
  const stories = applyStories(cfg, locale);
  const creative = creativePlan(cfg, device, plan, goldie.DEVICES[device].screenshot,
    (scene) => goldie.LAYOUTS[scene.layout ?? cfg.theme.layout]?.span ?? 1);
  const canvasModule = createRequire(join(root, "package.json"))("@napi-rs/canvas");
  // Goldie reports progress on stdout; keep stdout for this tool's JSON result.
  const log = console.log;
  console.log = (...args) => console.error(...args);
  let files;
  try {
    files = await goldie.renderScreenshots(cfg, device, locale);
  } finally {
    console.log = log;
  }
  const expected = goldie.DEVICES[device].screenshot;
  const composed = await composeCreative(canvasModule, files, plan, creative, expected, locale);
  const outputs = files.map((file) => {
    const size = pngSize(file);
    if (size.width !== expected.width || size.height !== expected.height) {
      fail(`${file} is ${size.width}x${size.height}, expected ${expected.width}x${expected.height}`);
    }
    if (size.colorType !== 2) fail(`${file} has an alpha channel or is not RGB`);
    return { path: file, sha256: sha256(file), width: size.width, height: size.height };
  });
  // D-085 (#401): Goldie's own image decorations (scene and theme) are generated material too, so the
  // record lists them with the tiles they appear on. With backgrounds and layers this is every image
  // input of every tile apart from the real captures; `inputInventory` says so to the proposal sheet.
  const screenshotScenes = cfg.scenes.filter((scene) => scene.kind === "screenshot");
  const tilesOf = new Map();
  for (const entry of tileMap(files, screenshotScenes.map((scene) => scene.id))) {
    tilesOf.set(entry.scene, [...(tilesOf.get(entry.scene) ?? []), entry.tile]);
  }
  const decorations = screenshotScenes.flatMap((scene) => [...(scene.decorations ?? []), ...(cfg.theme.decorations ?? [])]
    .filter((decoration) => decoration?.kind === "image")
    .map((decoration) => {
      const src = resolve(cfg.root, decoration.src);
      if (!existsSync(src)) fail(`decoration image of ${scene.id} not found: ${src}`);
      return { scene: scene.id, src, sha256: sha256(src), tiles: tilesOf.get(scene.id) ?? [] };
    }));
  const record = {
    schemaVersion: 1,
    goldieVersion: version,
    device,
    locale,
    config: configPath,
    inputInventory: "complete-v1",
    extensions: { layouts: [CONCEPT_LAYOUT], devices: { [IPHONE_KEY]: IPHONE_DEVICE, [IPAD_KEY]: IPAD_DEVICE } },
    backgrounds: composed.backgrounds,
    decorations,
    layers: composed.layers,
    popouts: composed.popouts,
    screens: composed.screens,
    stories,
    marks: composed.marks,
    files: outputs
  };
  writeFileSync(join(cfg.outDir, `creative-render-${device}-${locale}.json`), `${JSON.stringify(record, null, 2)}\n`);
  return record;
}

function parse(argv) {
  const [command, ...rest] = argv;
  const options = {};
  while (rest.length) {
    const key = rest.shift();
    if (!key?.startsWith("--")) fail(`unexpected argument: ${key}`);
    const value = rest.shift();
    if (value === undefined || value.startsWith("--")) fail(`missing value for ${key}`);
    const name = key.slice(2);
    if (name in options) fail(`duplicate option: ${key}`);
    options[name] = value;
  }
  return { command, options };
}

// --- D-085 (#391) product page header ----------------------------------------------------------------

// App Store product page header: 21:9, 3840x1646, opaque (Creative assets specifications). The art safe
// area was measured from the "Art Safe Area" layer of Apple's official Photoshop template; text, logos and
// the focal point stay inside it, which also keeps them clear of the back and share buttons in the top
// corners.
export const HEADER = { width: 3840, height: 1646 };
export const HEADER_SAFE_AREA = {
  x: 1097, y: 493, width: 1646, height: 661,
  source: {
    template: "creative_assets-product_page_header_template-static.psd (layer Art Safe Area)",
    url: "https://devimages-cdn.apple.com/design/resources/download/app-store/creative_assets-product_page_header_template-static.psd",
    checkedOn: "2026-10-22"
  }
};
// The top corners hold the back and share buttons; no protected layer may sit there. Apple gives no
// numbers for them, so these are the tool's margins (fractions of the header); check in the Preview tool.
export const HEADER_CLEAR_CORNERS = { width: 0.12, height: 0.2 };
export const HEADER_PROTECTED_ROLES = ["headline", "logo", "focal", "app-name", "claim", "key-number", "face"];

function headerSafeArea(value) {
  if (value === undefined) return HEADER_SAFE_AREA;
  if (!value || typeof value !== "object") fail("safeArea must be an object");
  for (const key of ["x", "y", "width", "height"]) {
    if (!Number.isInteger(value[key]) || value[key] < 0) fail(`safeArea ${key} must be a non-negative integer in header pixels`);
  }
  // A safe area is only as good as where it was measured: it must name the official template it came from.
  const source = value.source;
  if (!source || typeof source !== "object" || ["template", "url", "checkedOn"].some((key) => typeof source[key] !== "string" || !source[key].trim())) {
    fail("safeArea needs source: the official template, its URL and the date it was checked");
  }
  if (!/^https:\/\/(devimages-cdn\.apple\.com|developer\.apple\.com)\//.test(source.url)) fail("safeArea source url must be an Apple developer URL");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(source.checkedOn)) fail("safeArea source checkedOn must be a YYYY-MM-DD date");
  if (value.x + value.width > HEADER.width || value.y + value.height > HEADER.height || value.width === 0 || value.height === 0) {
    fail("safeArea must lie inside the 3840x1646 header");
  }
  return { x: value.x, y: value.y, width: value.width, height: value.height, source: { ...source } };
}

function inside(box, area) {
  return box.left >= area.x - 0.5 && box.top >= area.y - 0.5 && box.right <= area.x + area.width + 0.5 && box.bottom <= area.y + area.height + 0.5;
}

function rotatedBox(left, top, width, height, rotate) {
  const angle = ((rotate ?? 0) * Math.PI) / 180;
  const w = Math.abs(width * Math.cos(angle)) + Math.abs(height * Math.sin(angle));
  const h = Math.abs(width * Math.sin(angle)) + Math.abs(height * Math.cos(angle));
  const cx = left + width / 2;
  const cy = top + height / 2;
  return { left: cx - w / 2, right: cx + w / 2, top: cy - h / 2, bottom: cy + h / 2 };
}

// Renders a header still from a header spec: a background (#RRGGBB or an image that covers the header),
// image layers and text, all placed by fractions of the header. Text and every layer with a protected
// role must lie inside the safe area and outside the clear corners, or nothing is written.
export async function renderHeader({ runtime, spec: specPath, out }) {
  const { root } = await loadGoldie(runtime);
  const { createCanvas, loadImage } = createRequire(join(root, "package.json"))("@napi-rs/canvas");
  const specFile = resolve(specPath);
  const spec = JSON.parse(readFileSync(specFile, "utf8"));
  if (!spec || spec.schemaVersion !== 1) fail("header spec schemaVersion must be 1");
  const unknown = Object.keys(spec).filter((key) => !["schemaVersion", "background", "layers", "texts", "safeArea"].includes(key));
  if (unknown.length) fail(`unknown header spec field: ${unknown[0]}`);
  const base = dirname(specFile);
  const area = headerSafeArea(spec.safeArea);
  const corners = [
    { left: 0, top: 0, right: HEADER_CLEAR_CORNERS.width * HEADER.width, bottom: HEADER_CLEAR_CORNERS.height * HEADER.height },
    { left: (1 - HEADER_CLEAR_CORNERS.width) * HEADER.width, top: 0, right: HEADER.width, bottom: HEADER_CLEAR_CORNERS.height * HEADER.height }
  ];
  const overlapsCorner = (box) => corners.some((corner) => box.left < corner.right && box.right > corner.left && box.top < corner.bottom && box.bottom > corner.top);
  const output = resolve(out);
  if (existsSync(output)) fail(`header output already exists and is never replaced: ${output}`);
  const canvas = createCanvas(HEADER.width, HEADER.height);
  const ctx = canvas.getContext("2d");
  let background;
  if (typeof spec.background === "string") {
    if (!HEX.test(spec.background)) fail("header background must be #RRGGBB or { image }");
    ctx.fillStyle = spec.background;
    ctx.fillRect(0, 0, HEADER.width, HEADER.height);
    background = { color: spec.background.toUpperCase() };
  } else if (spec.background && typeof spec.background.image === "string") {
    const src = resolve(base, spec.background.image);
    if (!existsSync(src)) fail(`header background image not found: ${src}`);
    const image = await loadImage(src);
    const scale = Math.max(HEADER.width / image.width, HEADER.height / image.height);
    const sw = HEADER.width / scale;
    const sh = HEADER.height / scale;
    ctx.drawImage(image, (image.width - sw) / 2, (image.height - sh) / 2, sw, sh, 0, 0, HEADER.width, HEADER.height);
    background = { image: src, sha256: sha256(src) };
  } else {
    fail("header background must be #RRGGBB or { image }");
  }
  const layers = [];
  for (const [index, layer] of (spec.layers ?? []).entries()) {
    const label = `header layer ${index + 1}`;
    if (!layer || typeof layer.src !== "string") fail(`${label} needs src`);
    const src = resolve(base, layer.src);
    if (!existsSync(src)) fail(`${label} image not found: ${src}`);
    const size = pngSize(src);
    const place = placement(layer, label, {});
    const rotate = layer.rotate === undefined ? 0 : number(layer.rotate, `${label} rotate`, { min: -180, max: 180 });
    const role = layer.role ?? "decoration";
    const width = place.width * HEADER.width;
    const height = width * size.height / size.width;
    const left = place.x * HEADER.width;
    const top = place.y * HEADER.height;
    const box = rotatedBox(left, top, width, height, rotate);
    if (HEADER_PROTECTED_ROLES.includes(role)) {
      if (!inside(box, area)) fail(`${label} is marked ${role} and runs outside the safe area`);
      if (overlapsCorner(box)) fail(`${label} is marked ${role} and sits in a top corner under the buttons`);
    }
    const image = await loadImage(src);
    ctx.save();
    if (layer.shadow) {
      ctx.shadowColor = "rgba(0, 0, 0, 0.28)";
      ctx.shadowBlur = Math.round(HEADER.height * 0.02);
      ctx.shadowOffsetY = Math.round(HEADER.height * 0.008);
    }
    ctx.translate(left + width / 2, top + height / 2);
    if (rotate) ctx.rotate((rotate * Math.PI) / 180);
    ctx.drawImage(image, -width / 2, -height / 2, width, height);
    ctx.restore();
    layers.push({ index: index + 1, src, sha256: sha256(src), role, box });
  }
  const texts = [];
  for (const [index, entry] of (spec.texts ?? []).entries()) {
    const label = `header text ${index + 1}`;
    if (!entry || typeof entry.text !== "string" || !entry.text.trim()) fail(`${label} needs text`);
    const place = placement({ width: 1, ...entry }, label, {});
    const size = number(entry.size ?? 0.08, `${label} size`, { min: 0.01, max: 0.5 }) * HEADER.height;
    const color = entry.color ?? "#111111";
    if (!HEX.test(color)) fail(`${label} color must be #RRGGBB`);
    const font = entry.font ?? "Hiragino Sans";
    if (typeof font !== "string" || !/^[A-Za-z0-9 .'-]{1,64}$/.test(font)) fail(`${label} font must be a family name`);
    const weight = entry.weight ?? 700;
    const align = entry.align ?? "left";
    if (!["left", "center", "right"].includes(align)) fail(`${label} align must be left, center or right`);
    ctx.save();
    ctx.font = `${weight} ${Math.round(size)}px "${font}"`;
    ctx.fillStyle = color;
    ctx.textBaseline = "top";
    ctx.textAlign = align;
    const lines = entry.text.split("\n");
    const width = Math.max(...lines.map((line) => ctx.measureText(line).width));
    const height = lines.length * size * 1.2;
    const x = place.x * HEADER.width;
    const left = align === "left" ? x : align === "center" ? x - width / 2 : x - width;
    const box = { left, right: left + width, top: place.y * HEADER.height, bottom: place.y * HEADER.height + height };
    // Text is always protected: it must read on every device crop.
    if (!inside(box, area)) fail(`${label} runs outside the safe area`);
    if (overlapsCorner(box)) fail(`${label} sits in a top corner under the buttons`);
    lines.forEach((line, row) => ctx.fillText(line, x, box.top + row * size * 1.2));
    ctx.restore();
    texts.push({ index: index + 1, text: entry.text, box });
  }
  const rgba = `${output}.rgba.png`;
  writeFileSync(rgba, await canvas.encode("png"));
  execFileSync("ffmpeg", ["-y", "-loglevel", "error", "-i", rgba, "-vf", "format=rgb24", "-frames:v", "1", output], { stdio: ["ignore", "ignore", "inherit"] });
  unlinkSync(rgba);
  const size = pngSize(output);
  if (size.width !== HEADER.width || size.height !== HEADER.height || size.colorType !== 2) fail(`${output} is not an opaque 3840x1646 header`);
  const record = { schemaVersion: 1, kind: "product-page-header", output, sha256: sha256(output), width: size.width, height: size.height,
    safeArea: area, clearCorners: HEADER_CLEAR_CORNERS, background, layers, texts };
  writeFileSync(`${output}.json`, `${JSON.stringify(record, null, 2)}\n`);
  return record;
}

async function main(argv) {
  const { command, options } = parse(argv);
  const runtime = options.runtime ?? process.env.GOLDIE_RUNTIME ?? defaultRuntime();
  if (command === "describe") {
    const { goldie, version } = await loadGoldie(runtime);
    extend(goldie);
    return { goldieVersion: version, layouts: goldie.LAYOUT_KEYS, devices: Object.keys(goldie.DEVICES), iphone: goldie.DEVICES[IPHONE_KEY], ipad: goldie.DEVICES[IPAD_KEY] };
  }
  if (command === "render") {
    for (const name of ["config", "device", "locale"]) if (!options[name]) fail(`missing option: --${name}`);
    const unknown = Object.keys(options).filter((name) => !["config", "device", "locale", "runtime"].includes(name));
    if (unknown.length) fail(`unknown option: --${unknown[0]}`);
    return render({ runtime, config: options.config, device: options.device, locale: options.locale });
  }
  if (command === "render-header") {
    for (const name of ["spec", "out"]) if (!options[name]) fail(`missing option: --${name}`);
    const unknown = Object.keys(options).filter((name) => !["spec", "out", "runtime"].includes(name));
    if (unknown.length) fail(`unknown option: --${unknown[0]}`);
    return renderHeader({ runtime, spec: options.spec, out: options.out });
  }
  if (command === "describe-header") {
    return { header: HEADER, safeArea: HEADER_SAFE_AREA, clearCorners: HEADER_CLEAR_CORNERS, protectedRoles: HEADER_PROTECTED_ROLES };
  }
  fail("command is required: render, render-header, describe or describe-header");
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main(process.argv.slice(2)).then(
    (value) => process.stdout.write(`${JSON.stringify(value)}\n`),
    (error) => {
      process.stderr.write(`${error instanceof Failure ? error.message : error.stack ?? error}\n`);
      process.exit(1);
    }
  );
}
