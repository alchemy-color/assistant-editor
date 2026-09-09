# Releases

Prebuilt macOS app bundles, one per release. The current `Assistant Editor.app` is the latest build (v1.24).

## How to run

1. Download `Assistant Editor.app` (a single Finder-draggable copy — no installer).
2. Move it to your `/Applications` folder (or anywhere you like).
3. It is **ad-hoc signed** (no Apple Developer ID), so macOS Gatekeeper will quarantine it the first time. Open it once via **right-click → Open** and confirm, or clear the quarantine with:
   `xattr -dr com.apple.quarantine "Assistant Editor.app"`
4. Install [Ollama](https://ollama.com/download) and pull a model — the app walks you through this on first launch.

## Shipped as raw folder (not a Release asset)

The app bundle is committed to git as a plain folder so it lives in version history alongside the source. For end-user distribution, a **GitHub Release** with a `.zip` of this bundle is the canonical, more convenient route (download counts, one URL, no git clone needed).

To make a `.zip` of the current bundle:

```bash
cd Releases
zip -r Assistant-Editor-v1.24.7-macOS.zip "Assistant Editor.app"
```

Then attach it to a GitHub Release.

## Versioned snapshots

`dist/v1/` … `dist/v1.23/` under the project drive hold historical snapshots (source + built app + docs). This `Releases/` folder is the single current-app location in git.

## What it needs to do the job

- **Ollama** with a compatible model (default: `sonct988/gemma4-26b-a4b-it-q4km-256k`)
- **DaVinci Resolve** (Studio or Free) for timeline/marker creation
- **ffmpeg/ffprobe** for frame-rate detection and gap-clip generation
- The full manual is at `docs/MANUAL.md`; open in-app with **⌘?**.