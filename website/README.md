# Blabbit website

Static landing page for Blabbit. No build step: `index.html`, `styles.css`, `main.js` and the icons.

Run locally: `cd website && python3 -m http.server 4173`, then open http://localhost:4173.

Deploy: any static host. On Vercel, import the repo and set the root directory to `website/`; on GitHub Pages, publish from `website/` with a Pages workflow.

Downloads point at `https://github.com/vedjrr/Blabbit/releases/latest/download/Blabbit.dmg`, which `make release` produces (`build/release/Blabbit.dmg`) and the release must include. It always resolves to the newest release, so the site doesn't need an update per version.

The model scores in `#models` are the app's own (`ModelScores`, from `core/blabbit-core/models.json`). Update both together if the measurements change. Bump `?v=` on `styles.css`/`main.js` after editing them.
