#!/bin/bash
# Builds the release binary, signs it with a real identity and packs it into a .mcpb
# Claude extension bundle.
#
# An .mcpb is a zip with manifest.json at its root. There is no dependency on the
# `mcpb` CLI here: zip is enough, and it keeps the toolchain to what macOS ships.
#
#   MCPB_SIGN_IDENTITY="Apple Development: …" ./scripts/pack.sh
set -euo pipefail

NAME="moodle-mcp"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# A real identity is required, not merely preferred. The Keychain item's access list
# names this program by its designated requirement; an ad-hoc signature has none, so
# the trust would die with every rebuild and the unattended read would fail. The
# certificate's subject carries its holder's name: never publish a binary signed here.
IDENTITY="${MCPB_SIGN_IDENTITY:-}"
[ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ] \
  || { echo "!! set MCPB_SIGN_IDENTITY to a signing identity (security find-identity -v -p codesigning)" >&2; exit 1; }

# Apple silicon only. A universal build doubles the bundle and takes far longer to link.
echo "==> Building $NAME (arm64)"
swift build -c release

BINARY=".build/release/$NAME"
[ -f "$BINARY" ] || { echo "!! no release binary found" >&2; exit 1; }

ARCHS="$(lipo -archs "$BINARY")"
[ "$ARCHS" = "arm64" ] || { echo "!! expected arm64 only, got: $ARCHS" >&2; exit 1; }

echo "==> Checking the embedded Info.plist survived linking"
otool -P "$BINARY" | grep -q "codes.eneko.$NAME" \
  || { echo "!! Info.plist missing from $BINARY" >&2; exit 1; }

echo "==> Staging bundle"
STAGE="$ROOT/extension"
rm -rf "$STAGE/server"
mkdir -p "$STAGE/server"
cp "$BINARY" "$STAGE/server/$NAME"
chmod +x "$STAGE/server/$NAME"

# The identifier is pinned rather than inferred, because the designated requirement
# quotes it. Keep it in step with CFBundleIdentifier in Resources/Info.plist.
echo "==> Signing"
codesign --force --identifier "codes.eneko.$NAME" --sign "$IDENTITY" "$STAGE/server/$NAME"

# The designated requirement is what the Keychain access list anchors to. Printing it
# makes a silent regression to ad hoc visible at build time.
echo "==> Designated requirement"
REQUIREMENT=$(codesign -d -r- "$STAGE/server/$NAME" 2>&1 | grep "^designated" || true)
case "$REQUIREMENT" in
  *"certificate leaf"*) echo "    $REQUIREMENT" | sed -E 's/"[^"]*Apple Development[^"]*"/"<identity>"/' ;;
  *) echo "!! no certificate-based designated requirement: $REQUIREMENT" >&2; exit 1 ;;
esac

otool -P "$STAGE/server/$NAME" | grep -q "codes.eneko.$NAME" \
  || { echo "!! Info.plist lost during signing" >&2; exit 1; }

python3 -c "import json,sys; json.load(open('$STAGE/manifest.json'))" \
  || { echo "!! manifest.json is not valid JSON" >&2; exit 1; }

echo "==> Packing"
mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/$NAME.mcpb"
rm -f "$OUT"
FILES=(manifest.json server)
[ -f "$STAGE/icon.png" ] && FILES+=(icon.png)
# -X drops resource forks and extra attributes.
( cd "$STAGE" && zip -qrX "$OUT" "${FILES[@]}" )

echo "==> Verifying the executable bit survived"
MODE=$(unzip -Z "$OUT" "server/$NAME" | awk 'NR==1 {print $1}')
case "$MODE" in
  *x*) echo "    mode $MODE — executable" ;;
  *)   echo "!! executable bit lost: $MODE" >&2; exit 1 ;;
esac

echo
echo "Built $OUT ($(du -h "$OUT" | cut -f1)). Signed binary: $STAGE/server/$NAME"
echo "Never publish this bundle: it is signed with a personal certificate."
