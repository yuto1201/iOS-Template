# Reference research (D-093)

Look at real images of top apps before every proposal, then compare your own tiles with them at
the same height. A record of technique names alone is not enough: the reasons a set looks weak
(a small headline, a floating device, one decoration per tile, pale backgrounds) only show when
the images sit side by side.

## Collect the images

[before.click](https://before.click) lists apps with highly rated store images. Its pages are
drawn with JavaScript, but the explore page's HTML already holds every app's slug, and each
app's images are plain files, so `curl` is enough; no browser is needed. Keep everything outside
Git, next to the proposal's revision under `.artifacts/store-creative/` (ignored) or in a
temporary folder.

```sh
refs=.artifacts/store-creative/<revision>/refs
mkdir -p "$refs"
curl -fsS https://before.click/explore -o "$refs/explore.html"
grep -o '/apps/[a-z0-9-]*' "$refs/explore.html" | sort -u | head -40   # the app slugs
for slug in <slug-1> <slug-2> <slug-3>; do                           # 3–5 apps of the category
  mkdir -p "$refs/$slug"
  for n in 1 2 3 4 5; do
    curl -fsS "https://before.click/apps/$slug/aso/$n.webp" -o "$refs/$slug/$n.webp" || break
  done
done
```

Add the App Store pages of the category's top apps the same way when they help. These images
are other developers' work: look at them, record techniques in the
[research record](proposal.md#research-record), and never copy a design, illustration, headline
or logo, and never commit the images.

## Lay them out beside your tiles

```sh
tools/appstore-creative-compose.sh research-sheet --refs "$refs" \
  --mine <compose output folder> --out .artifacts/store-creative/<revision>/research
```

`research-sheet` draws one row per app with its first five images, and your tiles
(`tile-N.png` from `compose`) as the last row, all at the same height, as
`research-sheet.png` with a record of every image's SHA-256. It refuses an output folder inside
a Git working tree unless Git ignores it. Look at the sheet before building the proposal sheet,
and write down what the references do better: headline size and width, how far the device runs
off the edge, how many decorations a tile carries, background color, popouts. Fix those in the
style spec and the declarations, then compose again.

## Check the thumbnails

`compose` also writes `thumbnails.png`, every tile at 220 px wide (the size of a search result).
Before the user sees a sheet, say for the set in one sentence what the app is and why someone
would install it, from the thumbnails alone. If you cannot, the set is not ready.
