import type { GoldieConfig } from "goldie";
import { isAbsolute } from "node:path";

function required(name: string): string {
  const value = process.env[name];
  if (!value?.trim()) throw new Error(`Set ${name} before using this starter`);
  return value;
}
const appRoot = required("GOLDIE_APP_ROOT");
const appPath = required("GOLDIE_APP_PATH");
const bundleId = required("GOLDIE_BUNDLE_ID");
const locale = required("GOLDIE_LOCALE");
if (!isAbsolute(appRoot) || !isAbsolute(appPath))
  throw new Error("GOLDIE_APP_ROOT and GOLDIE_APP_PATH must be absolute paths");
if (!["ja", "en-US"].includes(locale))
  throw new Error("Create a separate config directory for ja or en-US");

// iPad 13-inch starter for the appstore-creative render extension (D-077). Render it only with
//   tools/appstore-creative-render.sh render --config <this file> --device ipad-13 --locale <locale>
// Goldie's own CLI has no iPad device. Keep it beside the iPhone config as
// goldie/<locale>/goldie.ipad.config.ts; replace scene IDs and copy from the actual app.
const config: GoldieConfig = {
  appRoot, appPath, bundleId,
  devices: ["ipad-13"],
  locales: [locale],
  appearance: "light",
  frame: { variant: "17-pro-silver" },
  theme: {
    background: "#F3F1EB",
    headlineColor: "#171717",
    subheadColor: "#53534D",
    fontFamily: '"Hiragino Sans", -apple-system, sans-serif',
    copyHeightRatio: 0.2,
    deviceWidthRatio: 0.7,
    layout: "classic",
  },
  // Local Studio scaffolding; these are not claims for publication.
  store: {
    name: "App name",
    subtitle: { ja: "アプリの説明", "en-US": "App description" },
    developer: "", category: "", rating: 0, ratingCount: "",
    ageRating: "", price: "",
    description: { ja: "", "en-US": "" },
  },
  // The capture for each scene comes from out/raw/ipad-13/manifest.json.
  scenes: [{
    kind: "screenshot", id: "home", flow: `store-${locale}-home`,
    headline: { ja: "大切なことを、ひと目で", "en-US": "See what matters" },
  }],
};
export default config;
