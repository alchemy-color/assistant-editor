# Security Policy

## Project scope

Assistant Editor is a **local-first desktop application**. All AI processing (LLM calls, embeddings) runs on the user's own machine via the local oMLX server — no data leaves the computer, and there is no cloud backend or telemetry.

This repository is the **cross-platform porting source** for a macOS reference app. The reference app is not distributed through a public store; it is built and run by the author and authorized collaborators.

## Reporting a vulnerability

If you find a security issue, **do not open a public issue**. Report it privately instead:

- GitHub private security advisories: https://github.com/alchemy-color/assistant-editor/security/advisories
- Direct email (preferred for sensitive reports) — request the address from the repository owner via a private advisory.

Please include:

1. The affected component (Swift UI layer, Python pipeline, or `PythonBridge` runner) and file where possible.
2. Steps to reproduce, ideally minimal.
3. Impact, and any proposed fix.

We aim to acknowledge reports within **5 business days** and to coordinate a fix before public disclosure.

## What is in scope

Given the porting/education purpose of this repository, the areas that can realistically affect end users are:

- **Python pipeline scripts** (`source/Python/`): file parsing, subprocess execution, LLM prompt construction. Path handling, symlink traversal, and any shell/`Popen` usage.
- **`PythonBridge` + Resolve bridge** (macOS reference): anything that executes local commands or talks to DaVinci Resolve's scripting API.
- **Prompt injection** into LLM calls fed by untrusted transcript/subtitle files (chapters, synopses, chat context).

## Not in scope

- Known upstream limitations documented in the repo (e.g., resolved markers' missing color support in Resolve's `AddMarker` API).
- Issues that require the user to already have malicious code running locally (the app intentionally executes local scripts and talks to a local LLM server).

## Supported versions

Only the latest tagged commit of the macOS reference app is supported. The repository's historical versioned snapshots (`dist/v1.x/`) are archival.