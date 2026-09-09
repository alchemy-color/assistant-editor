#!/bin/bash
# Assistant Editor — Xcode project setup
# Usage: sh setup.sh
# Requires: Homebrew, Xcode 15+

set -euo pipefail

echo "⟳ Checking for xcodegen…"
if ! command -v xcodegen &>/dev/null; then
    echo "  Installing xcodegen…"
    brew install xcodegen
fi

echo "⟳ Generating Xcode project…"
cd "$(dirname "$0")"
xcodegen generate

echo "✓ Project created: Assistant Editor.xcodeproj"
echo ""
echo "Next steps:"
echo "  1. open Assistant Editor.xcodeproj"
echo "  2. Select Assistant Editor target → Signing & Capabilities → set your Team"
echo "  3. Build (Cmd+B) — the Python scripts are copied in a pre-build phase"
echo ""
echo "To run from terminal without Xcode:"
echo "  xcodebuild -project \"Assistant Editor.xcodeproj\" -scheme \"Assistant Editor\" build"
