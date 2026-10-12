// D-077: the appstore-creative render extension. It drives the pinned Goldie 0.3.1 through its
// published modules and adds, inside this process only, what Goldie lacks: a `concept` layout that
// draws copy and image layers with no device, an iPhone 6.3-inch device (1206x2622, D-079), an iPad
// 13-inch device (2064x2752, bare screen), and
// background images under the copy (Goldie draws its image layers over the headline). Goldie's own
// layouts render exactly as before when a config uses none of these, and the installed runtime is
// never written to.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
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

function compositeBackgrounds(files, plan, tile) {
  const slices = new Map();
  for (const file of files) {
    const name = basename(file).replace(/^\d{2}-/, "").replace(/\.png$/, "");
    for (const id of plan.keys()) {
      const match = name === id ? 0 : name.startsWith(`${id}-`) && /^\d+$/.test(name.slice(id.length + 1)) ? Number(name.slice(id.length + 1)) - 1 : null;
      if (match !== null) slices.set(file, { id, slice: match });
    }
  }
  const spans = new Map();
  for (const { id } of slices.values()) spans.set(id, (spans.get(id) ?? 0) + 1);
  const used = [];
  for (const [file, { id, slice }] of slices) {
    const { src, strip, index } = plan.get(id);
    const span = spans.get(id);
    const tiles = strip ?? span;
    if (index + span > tiles) fail(`backgroundImage of ${id} runs past its strip of ${tiles} tiles`);
    const x = ((strip === null ? 0 : index) + slice) * tile.width;
    const width = tiles * tile.width;
    const output = join(dirname(file), `.composite-${basename(file)}`);
    execFileSync("ffmpeg", [
      "-y", "-loglevel", "error", "-i", src, "-i", file, "-filter_complex",
      `[0:v]scale=${width}:${tile.height}:force_original_aspect_ratio=increase:flags=lanczos,` +
        `crop=${width}:${tile.height},crop=${tile.width}:${tile.height}:${x}:0[bg];[bg][1:v]overlay=0:0:format=auto,format=rgb24`,
      "-frames:v", "1", output
    ], { stdio: ["ignore", "ignore", "inherit"] });
    renameSync(output, file);
    used.push({ file, scene: id, source: src, sourceSha256: sha256(src), strip: tiles, tile: (strip === null ? 0 : index) + slice });
  }
  return used;
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
  const backgrounds = compositeBackgrounds(files, plan, expected);
  const outputs = files.map((file) => {
    const size = pngSize(file);
    if (size.width !== expected.width || size.height !== expected.height) {
      fail(`${file} is ${size.width}x${size.height}, expected ${expected.width}x${expected.height}`);
    }
    if (size.colorType !== 2) fail(`${file} has an alpha channel or is not RGB`);
    return { path: file, sha256: sha256(file), width: size.width, height: size.height };
  });
  const record = {
    schemaVersion: 1,
    goldieVersion: version,
    device,
    locale,
    config: configPath,
    extensions: { layouts: [CONCEPT_LAYOUT], devices: { [IPHONE_KEY]: IPHONE_DEVICE, [IPAD_KEY]: IPAD_DEVICE } },
    backgrounds,
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
  fail("command is required: render or describe");
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
