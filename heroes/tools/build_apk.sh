#!/usr/bin/env bash
# Build a signed arm64 Android APK of «Хроники двоих» without the Android SDK.
#
# Usage:  tools/build_apk.sh [version_name] [version_code]
#   no args        -> use version/name + version/code from export_presets.cfg
#   name only      -> set version/name, auto-increment version/code
#   name + code    -> set both
# Output: build/chronicles-<version_name>.apk  (zipaligned, v1+v2+v3 signed)
#
# Env overrides: GODOT, UBER_JAR, KEYSTORE, KEYSTORE_INFO, FAKE_SDK, DEBUG_EXPORT=1
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="${TOOLS:-/home/user/tools}"
GODOT="${GODOT:-$TOOLS/Godot_v4.3-stable_linux.x86_64}"
UBER_JAR="${UBER_JAR:-$TOOLS/uber.jar}"
KEYSTORE="${KEYSTORE:-/mnt/project-files/keys/heroes-release.keystore}"
KEYSTORE_INFO="${KEYSTORE_INFO:-/mnt/project-files/keys/heroes-keystore.txt}"
KEY_ALIAS="heroes"
FAKE_SDK="${FAKE_SDK:-$HOME/.local/share/godot-fake-android-sdk}"
PRESET_FILE="$PROJ/export_presets.cfg"
PRESET="Android"
TPL_DIR="$HOME/.local/share/godot/export_templates/4.3.stable"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

for f in "$GODOT" "$UBER_JAR" "$PRESET_FILE" "$TPL_DIR/android_release.apk"; do
  [ -e "$f" ] || die "missing $f"
done
command -v java >/dev/null || die "java not found"

# ---------- version handling ----------
cur_name=$(sed -n 's/^version\/name="\(.*\)"$/\1/p' "$PRESET_FILE" | head -1)
cur_code=$(sed -n 's/^version\/code=\([0-9]*\)$/\1/p' "$PRESET_FILE" | head -1)
VNAME="${1:-$cur_name}"
if [ $# -ge 2 ]; then VCODE="$2"
elif [ $# -ge 1 ] && [ "$1" != "$cur_name" ]; then VCODE=$((cur_code + 1))
else VCODE="$cur_code"; fi
[[ "$VCODE" =~ ^[0-9]+$ ]] || die "version_code must be an integer: $VCODE"
[[ "$VNAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "version_name may only contain A-Za-z0-9._- : $VNAME"
sed -i -e "s/^version\/name=.*/version\/name=\"$VNAME\"/" \
       -e "s/^version\/code=.*/version\/code=$VCODE/" "$PRESET_FILE"
log "version name=$VNAME code=$VCODE"

# ---------- fake Android SDK (Godot 4.3 only checks that these exist) ----------
# platform-tools/adb       -> stub (never used for export)
# build-tools/<v>/apksigner -> real apksigner (extracted from uber.jar); only
#                             used if package/signed=true, which we don't.
if [ ! -x "$FAKE_SDK/build-tools/33.0.2/apksigner" ]; then
  log "creating fake Android SDK at $FAKE_SDK"
  mkdir -p "$FAKE_SDK/platform-tools" "$FAKE_SDK/build-tools/33.0.2" "$FAKE_SDK/cmdline-tools/latest/bin"
  printf '#!/bin/sh\necho "fake adb (no Android SDK installed)" >&2\nexit 1\n' > "$FAKE_SDK/platform-tools/adb"
  unzip -p "$UBER_JAR" lib/apksigner_33_0_2.jar > "$FAKE_SDK/build-tools/33.0.2/apksigner.jar"
  printf '#!/bin/sh\nexec java -jar "$(dirname "$0")/apksigner.jar" "$@"\n' > "$FAKE_SDK/build-tools/33.0.2/apksigner"
  printf '#!/bin/sh\nexit 0\n' > "$FAKE_SDK/cmdline-tools/latest/bin/sdkmanager"
  chmod +x "$FAKE_SDK/platform-tools/adb" "$FAKE_SDK/build-tools/33.0.2/apksigner" \
           "$FAKE_SDK/cmdline-tools/latest/bin/sdkmanager"
fi

# ---------- editor settings: android_sdk_path / java_sdk_path ----------
JAVA_HOME_GUESS="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")}"
ES_DIR="$HOME/.config/godot"; ES="$ES_DIR/editor_settings-4.3.tres"
mkdir -p "$ES_DIR"
if [ ! -f "$ES" ]; then
  printf '[gd_resource type="EditorSettings" format=3]\n\n[resource]\n' > "$ES"
fi
set_es() { # key value
  if grep -q "^$1 = " "$ES"; then sed -i "s|^$1 = .*|$1 = \"$2\"|" "$ES"
  else echo "$1 = \"$2\"" >> "$ES"; fi
}
set_es "export/android/android_sdk_path" "$FAKE_SDK"
set_es "export/android/java_sdk_path" "$JAVA_HOME_GUESS"

# ---------- export (unsigned) ----------
mkdir -p "$PROJ/build"
UNSIGNED="$PROJ/build/chronicles-unsigned.apk"
OUT="$PROJ/build/chronicles-$VNAME.apk"
rm -f "$UNSIGNED"
LOG="$PROJ/build/export.log"
if [ ! -d "$PROJ/.godot/imported" ]; then
  log "first run: importing assets"
  timeout 300 "$GODOT" --headless --path "$PROJ" --import >"$PROJ/build/import.log" 2>&1 || true
fi
MODE="--export-release"; [ "${DEBUG_EXPORT:-0}" = 1 ] && MODE="--export-debug"
log "exporting ($MODE) -> $UNSIGNED"
set +e
timeout 600 "$GODOT" --headless --path "$PROJ" "$MODE" "$PRESET" "$UNSIGNED" >"$LOG" 2>&1
rc=$?
set -e
grep -E "ERROR|SCRIPT ERROR|Parse Error" "$LOG" | sed 's/^/   godot: /' | head -40 || true
[ -s "$UNSIGNED" ] || die "Godot export failed (rc=$rc), see $LOG"
LISTING=$(unzip -l "$UNSIGNED")
grep -q "lib/arm64-v8a/libgodot_android.so" <<<"$LISTING" || die "APK lacks arm64 lib"
grep -q " assets/" <<<"$LISTING" || die "APK lacks assets/"

# ---------- zipalign + sign ----------
[ -f "$KEYSTORE" ] || die "keystore $KEYSTORE not found (see heroes-keystore.txt instructions)"
[ -f "$KEYSTORE_INFO" ] || die "keystore info $KEYSTORE_INFO not found"
KS_PASS=$(sed -n 's/^storepass=//p' "$KEYSTORE_INFO")
KEY_PASS=$(sed -n 's/^keypass=//p' "$KEYSTORE_INFO"); KEY_PASS="${KEY_PASS:-$KS_PASS}"
[ -n "$KS_PASS" ] || die "no storepass= in $KEYSTORE_INFO"
SIGN_DIR=$(mktemp -d)
trap 'rm -rf "$SIGN_DIR"' EXIT
log "zipalign + sign with $KEYSTORE (alias $KEY_ALIAS)"
java -jar "$UBER_JAR" -a "$UNSIGNED" -o "$SIGN_DIR" \
     --ks "$KEYSTORE" --ksAlias "$KEY_ALIAS" --ksPass "$KS_PASS" --ksKeyPass "$KEY_PASS" \
     >"$PROJ/build/sign.log" 2>&1 || { cat "$PROJ/build/sign.log"; die "signing failed"; }
SIGNED=$(ls "$SIGN_DIR"/*.apk | head -1)
[ -f "$SIGNED" ] || { cat "$PROJ/build/sign.log"; die "signer produced no apk"; }
mv -f "$SIGNED" "$OUT"
rm -f "$UNSIGNED"

log "verifying"
java -jar "$UBER_JAR" --onlyVerify -a "$OUT" 2>&1 | grep -E "VERIFY|signature|Signature|zipalign|ERROR|\[v" | head -20 || true
ls -la "$OUT"
echo "OK: $OUT"
