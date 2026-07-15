#!/usr/bin/env bash
# Impacchetta Zuer in un APK (M1: NativeActivity + finestra zicro), da Linux e
# SENZA Gradle: `zig build android` produce libzuer.so, poi aapt2 + zipalign +
# apksigner fanno il pacchetto. È la catena minima — nessun classes.dex, perché
# l'activity è quella nativa del framework (vedi android/AndroidManifest.xml).
#
# Uso:  scripts/build-android-apk.sh [--no-build] [--install] [--out FILE.apk]
#   --no-build  non ricompila libzuer.so (riusa zig-out/android/lib/…)
#   --install   installa l'APK sul dispositivo/emulatore collegato (adb install -r)
#   --out       percorso dell'APK prodotto (default: zig-out/android/Zuer.apk)
#
# Richiede: Android SDK (aapt2, zipalign, apksigner, platforms/android-NN) e NDK.
# Path da $ANDROID_HOME / $ANDROID_NDK_HOME, oppure --sdk/--ndk.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
NDK="${ANDROID_NDK_HOME:-}"
OUT="$ROOT/zig-out/android/Zuer.apk"
DO_BUILD=1
DO_INSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) DO_BUILD=0; shift ;;
    --install)  DO_INSTALL=1; shift ;;
    --out)      OUT="$2"; shift 2 ;;
    --sdk)      SDK="$2"; shift 2 ;;
    --ndk)      NDK="$2"; shift 2 ;;
    *) echo "opzione sconosciuta: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$SDK" && -d "$SDK" ]] || { echo "✗ Android SDK non trovato: esporta ANDROID_HOME o passa --sdk"; exit 1; }
[[ -n "$NDK" && -d "$NDK" ]] || { echo "✗ Android NDK non trovato: esporta ANDROID_NDK_HOME o passa --ndk"; exit 1; }

# La platform più recente installata (android.jar = le API contro cui aapt2 linka)
# e le build-tools più recenti (aapt2/zipalign/apksigner).
PLATFORM="$(ls -d "$SDK"/platforms/android-* 2>/dev/null | sort -V | tail -1)"
[[ -n "$PLATFORM" && -f "$PLATFORM/android.jar" ]] || { echo "✗ nessuna platform con android.jar in $SDK/platforms"; exit 1; }
TOOLS="$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1)"
AAPT2="$(command -v aapt2 || echo "$TOOLS/aapt2")"
ZIPALIGN="$(command -v zipalign || echo "$TOOLS/zipalign")"
APKSIGNER="$(command -v apksigner || echo "$TOOLS/apksigner")"
for t in "$AAPT2" "$ZIPALIGN" "$APKSIGNER"; do
  [[ -x "$t" ]] || { echo "✗ tool mancante: $t (installa le build-tools dell'SDK)"; exit 1; }
done

TARGET_SDK="$(basename "$PLATFORM" | sed 's/android-//' | cut -d. -f1)"
MIN_SDK=24  # deve combaciare con l'android_api_level dello step `android` in build.zig

if [[ $DO_BUILD -eq 1 ]]; then
  echo "→ [1/5] zig build android (libzuer.so, aarch64)"
  ANDROID_NDK_HOME="$NDK" zig build android
fi
SO="$ROOT/zig-out/android/lib/arm64-v8a/libzuer.so"
[[ -f "$SO" ]] || { echo "✗ $SO assente: esegui senza --no-build"; exit 1; }

STAGE="$ROOT/zig-out/android/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE/res/mipmap-xxhdpi" "$STAGE/lib/arm64-v8a"

echo "→ [2/5] risorse (tema + icona launcher)"
# Risorse scritte a mano (il tema fullscreen): l'icona invece è generata qui sotto.
cp -r "$ROOT/android/res/." "$STAGE/res/"
if command -v magick >/dev/null; then
  # Stessa "Z" bianca su tondo blu di Windows/macOS, alle densità che il launcher usa.
  for d in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
    dpi="${d%%:*}"; s="${d##*:}"
    mkdir -p "$STAGE/res/mipmap-$dpi"
    magick -size ${s}x${s} xc:none \
      -fill '#2563eb' -draw "roundrectangle $((s/16)),$((s/16)) $((s-1-s/16)),$((s-1-s/16)) $((s*3/16)),$((s*3/16))" \
      -fill white -font DejaVu-Sans-Bold -pointsize $((s*3/5)) -gravity center -annotate +0-$((s/48)) 'Z' \
      "$STAGE/res/mipmap-$dpi/ic_launcher.png" 2>/dev/null || true
  done
fi
if [[ ! -f "$STAGE/res/mipmap-xxhdpi/ic_launcher.png" ]]; then
  # Senza ImageMagick: un PNG blu 1×1 (l'icona non è il punto di M1, ma il manifest
  # referenzia @mipmap/ic_launcher e aapt2 fallirebbe se la risorsa non esistesse).
  printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc`\x98\xc1\x00\x00\x01\x1b\x00\x9a\x1c\x1e\xd0\x00\x00\x00\x00IEND\xaeB\x82' \
    > "$STAGE/res/mipmap-xxhdpi/ic_launcher.png"
  echo "  · ImageMagick assente: icona segnaposto"
fi

echo "→ [3/5] aapt2 (manifest + risorse → APK base)"
mkdir -p "$STAGE/compiled"
"$AAPT2" compile --dir "$STAGE/res" -o "$STAGE/compiled/res.zip" >/dev/null
"$AAPT2" link \
  -I "$PLATFORM/android.jar" \
  --manifest "$ROOT/android/AndroidManifest.xml" \
  --min-sdk-version "$MIN_SDK" --target-sdk-version "$TARGET_SDK" \
  -o "$STAGE/base.apk" \
  "$STAGE/compiled/res.zip" >/dev/null

echo "→ [4/5] libreria nativa nel pacchetto"
cp "$SO" "$STAGE/lib/arm64-v8a/"
# La .so va STORED (non compressa) e allineata a 4 KiB: così il loader la mappa
# direttamente dall'APK (extractNativeLibs implicito a false su SDK ≥ 23) senza
# scompattarla. `zip -0` + `zipalign -p` sono esattamente questo contratto.
( cd "$STAGE" && zip -q -0 -X base.apk lib/arm64-v8a/libzuer.so )

echo "→ [5/5] zipalign + firma (debug keystore)"
KS="$HOME/.android/debug.keystore"
if [[ ! -f "$KS" ]]; then
  echo "  · genero il debug keystore"
  mkdir -p "$(dirname "$KS")"
  keytool -genkeypair -keystore "$KS" -storepass android -keypass android \
    -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1
fi
mkdir -p "$(dirname "$OUT")"
"$ZIPALIGN" -f -p 4 "$STAGE/base.apk" "$STAGE/aligned.apk"
"$APKSIGNER" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --ks-key-alias androiddebugkey --out "$OUT" "$STAGE/aligned.apk"
"$APKSIGNER" verify "$OUT" >/dev/null && echo "  ✓ firma verificata"

echo
echo "✓ APK: $OUT ($(du -h "$OUT" | cut -f1))"
echo "  minSdk $MIN_SDK · targetSdk $TARGET_SDK · abi arm64-v8a"

if [[ $DO_INSTALL -eq 1 ]]; then
  echo
  echo "→ adb install -r"
  adb install -r "$OUT"
  adb shell monkey -p dev.zuer.viewer -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  echo "✓ installato e avviato (log: adb logcat -s zuer:V threaded_app:V)"
fi
