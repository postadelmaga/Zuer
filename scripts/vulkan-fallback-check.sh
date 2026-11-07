#!/usr/bin/env bash
# Vulkan opzionale (§ loader a runtime): il renderer GPU si accende solo se loader,
# driver, device e coda grafica ci sono; altrimenti Zuer parte lo stesso e lo dice.
# Ogni condizione è simulata senza toccare il sistema:
#   - loader assente       ZUER_VULKAN_LOADER=none / percorso inesistente
#   - loader non valido    ZUER_VULKAN_LOADER=<lib senza vkGetInstanceProcAddr>
#   - nessun driver        VK_DRIVER_FILES / VK_ICD_FILENAMES su un file inesistente
#   - guasti iniettati     ZUER_TEST_VK_FAIL=instance|enumerate|nogpu|device
#   - device perso         ZUER_TEST_VK_LOST_AFTER=N (+ _REPEAT: ripiego definitivo)
# Parte 1: gpu-selftest headless (errore distinto per ogni condizione). Parte 2, con
# WAYLAND_DISPLAY: la GUI apre un cubo .obj e un .txt e resta viva in ogni scenario.
#
#   scripts/vulkan-fallback-check.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d); gp=
trap '[ -n "$gp" ] && kill -9 $gp 2>/dev/null; rm -rf "$W"' EXIT
fail=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FALLITO: $1"; fail=1; fi; }

(cd "$ROOT" && nice zig build -j2 gpu-selftest >/dev/null 2>&1) || { echo "FALLITO: build gpu-selftest"; exit 1; }
ST=$(ls -t "$ROOT"/.zig-cache/o/*/gpu-selftest | head -1)
NOLIB=$(ldconfig -p | awk '/libz\.so\.1 /{print $NF; exit}')
nodrv="VK_DRIVER_FILES=$W/none.json VK_ICD_FILENAMES=$W/none.json"
st() { # $1 atteso ("OK" o nome errore), $2.. ambiente
    local want=$1; shift
    env "$@" timeout 60 "$ST" > "$W/st.log" 2>&1; local rc=$?
    if [ "$want" = OK ]; then check "selftest [${*:-vulkan reale}] → OK" "[ $rc -eq 0 ] && grep -q '\[selftest\] OK' '$W/st.log'"
    else check "selftest [$*] → $want" "[ $rc -ne 0 ] && [ $rc -ne 124 ] && grep -q 'error: $want' '$W/st.log'"; fi
}
st OK
st VulkanLoaderMissing ZUER_VULKAN_LOADER=none
st VulkanLoaderMissing ZUER_VULKAN_LOADER=$W/libvulkan-assente.so
st VulkanLoaderInvalid ZUER_VULKAN_LOADER=$NOLIB
st VulkanNoDriver $nodrv
st VulkanInstanceFailed ZUER_TEST_VK_FAIL=instance
st VulkanEnumerateFailed ZUER_TEST_VK_FAIL=enumerate
st NoGpu ZUER_TEST_VK_FAIL=nogpu
st VulkanDeviceFailed ZUER_TEST_VK_FAIL=device

[ -n "${WAYLAND_DISPLAY:-}" ] || { echo "(senza WAYLAND_DISPLAY: parte GUI saltata)"; exit $fail; }
G=$ROOT/zig-out/bin/zuer-gui
python3 - "$W/cube.obj" <<'PY'
import sys
v=[(x,y,z) for x in (0,1) for y in (0,1) for z in (0,1)]
f=[(1,2,4,3),(5,7,8,6),(1,5,6,2),(3,4,8,7),(1,3,7,5),(2,6,8,4)]
with open(sys.argv[1],'w') as o:
    for p in v: o.write('v %d %d %d\n'%p)
    for q in f: o.write('f %d %d %d\nf %d %d %d\n'%(q[0],q[1],q[2],q[0],q[2],q[3]))
PY
printf 'testo di prova\n' > "$W/a.txt"
gui() { # $1 etichetta, $2 file, $3 secondi, $4.. ambiente → log in $W/gui.log
    local label=$1 file=$2 secs=$3; shift 3
    env ZUER_NO_CRASH_REPORT=1 "$@" "$G" "$file" > "$W/gui.log" 2>&1 & gp=$!
    sleep "$secs"
    check "GUI [$label] viva dopo ${secs}s" "kill -0 $gp 2>/dev/null"
    kill -9 $gp 2>/dev/null; wait $gp 2>/dev/null; gp=
}
gui "vulkan reale, cubo" "$W/cube.obj" 4
check "  renderer GPU acceso" "grep -q 'zuer gpu: using' '$W/gui.log'"
for sc in "ZUER_VULKAN_LOADER=none:VulkanLoaderMissing" "$nodrv:VulkanNoDriver" "ZUER_TEST_VK_FAIL=enumerate:VulkanEnumerateFailed" "ZUER_TEST_VK_FAIL=device:VulkanDeviceFailed"; do
    envs=${sc%:*}; want=${sc##*:}
    gui "$want, cubo" "$W/cube.obj" 4 $envs
    check "  renderer spento con $want, motivo mostrato" "grep -q 'init renderer Vulkan fallita: $want' '$W/gui.log'"
    gui "$want, testo" "$W/a.txt" 3 $envs
done
gui "device perso una volta" "$W/cube.obj" 6 ZUER_TEST_VK_LOST_AFTER=3
check "  perdita rilevata e renderer ricostruito" "grep -q 'device Vulkan perso, ricostruisco' '$W/gui.log' && [ \$(grep -c 'zuer gpu: using' '$W/gui.log') -ge 2 ]"
check "  nessun ripiego definitivo" "! grep -q 'renderer GPU spento' '$W/gui.log'"
gui "device perso sempre" "$W/cube.obj" 10 ZUER_TEST_VK_LOST_AFTER=3 ZUER_TEST_VK_LOST_REPEAT=1
check "  ripiego definitivo dopo i tentativi" "grep -q 'renderer GPU spento' '$W/gui.log'"
exit $fail
