#!/usr/bin/env bash
# Benchmark ripetibile di zuer-gui in riproduzione (Linux, sessione Wayland, anche
# headless). Per ogni modalità × clip × ripetizione: apre il clip, lascia sparire i
# controlli, misura per DUR secondi la CPU di zuer-gui, del compositor e dell'intero
# sistema, RSS e fd; poi stampa media, mediana e deviazione standard.
#
#   COMPOSITOR_PID=<pid> scripts/video-bench-gui.sh [REP] [DUR] clip1 [clip2 ...]
#
# Modalità: `dmabuf` (piano video del compositor) e `readback` (ZUER_VIDEO_PLANE=0).
# ZUER_GUI=<eseguibile> per misurare un'altra build (es. una versione precedente:
# la modalità `readback` è allora quella che quella build fa di suo). Audio muto:
# mpv con ao=null. Registra il carico medio di sistema prima e dopo: misure con
# carico diverso non sono confrontabili.
set -euo pipefail

REP=${1:-5}; DUR=${2:-6}; shift 2 || true
[ $# -gt 0 ] || { echo "uso: COMPOSITOR_PID=<pid> $0 [REP] [DUR] clip..."; exit 2; }
[ -n "${WAYLAND_DISPLAY:-}" ] || { echo "serve WAYLAND_DISPLAY"; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GUI=${ZUER_GUI:-$ROOT/zig-out/bin/zuer-gui}
MODES=${MODES:-dmabuf readback}
CPID=${COMPOSITOR_PID:-}
HZ=$(getconf CLK_TCK)
TMP_R=$(mktemp); TMP_L=$(mktemp); trap 'rm -f "$TMP_R" "$TMP_L"' EXIT
export ZUER_MPV_OPTS="${ZUER_MPV_OPTS:-ao=null}"

ticks() { awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }
sys_busy() { awk '/^cpu /{print $2+$3+$4+$7+$8, $2+$3+$4+$5+$6+$7+$8}' /proc/stat; }
stats() { # media mediana dev su stdin (un numero per riga)
    sort -n | awk '{v[NR]=$1; s+=$1; q+=$1*$1} END{m=s/NR; med=(NR%2)?v[(NR+1)/2]:(v[NR/2]+v[NR/2+1])/2; sd=sqrt((q/NR)-m*m); if(sd<0)sd=0; printf "media=%.1f mediana=%.1f dev=%.1f n=%d", m, med, sd, NR}'
}

echo "# $(date -Is) $(uname -r) carico: $(cut -d' ' -f1-3 /proc/loadavg) gui=$GUI"
for clip in "$@"; do
    for mode in $MODES; do
        env_mode=()
        [ "$mode" = readback ] && env_mode=(ZUER_VIDEO_PLANE=0)
        : > "$TMP_R"
        for r in $(seq 1 "$REP"); do
            env "${env_mode[@]}" "$GUI" "$clip" > "$TMP_L" 2>&1 &
            gp=$!
            sleep 4 # apertura + controlli che spariscono (2.5 s di inattività)
            g0=$(ticks $gp); c0=$( [ -n "$CPID" ] && ticks "$CPID" || echo 0 ); read -r b0 t0 < <(sys_busy)
            sleep "$DUR"
            g1=$(ticks $gp); c1=$( [ -n "$CPID" ] && ticks "$CPID" || echo 0 ); read -r b1 t1 < <(sys_busy)
            rss=$(awk '/VmRSS/{print int($2/1024)}' /proc/$gp/status)
            fds=$(ls /proc/$gp/fd | wc -l)
            plane=$(grep -q "piano dmabuf attivo" "$TMP_L" && echo dmabuf || echo readback)
            kill $gp; wait $gp 2>/dev/null || true
            ncpu=$(nproc)
            echo "$(( (g1-g0)*100/HZ/DUR )) $(( (c1-c0)*100/HZ/DUR )) $(awk -v b=$((b1-b0)) -v t=$((t1-t0)) -v n=$ncpu 'BEGIN{printf "%d", (t>0)?b*100*n/t:0}') $rss $fds $plane" >> "$TMP_R"
        done
        echo "$(basename "$clip") [$mode] percorso_reale=$(awk '{print $6}' "$TMP_R" | sort -u | tr '\n' ' ')"
        echo "  cpu_zuer%       $(awk '{print $1}' "$TMP_R" | stats)"
        [ -n "$CPID" ] && echo "  cpu_compositor% $(awk '{print $2}' "$TMP_R" | stats)"
        echo "  cpu_sistema%    $(awk '{print $3}' "$TMP_R" | stats)  (100% = un core)"
        echo "  rss_mb          $(awk '{print $4}' "$TMP_R" | stats)"
        echo "  fd              $(awk '{print $5}' "$TMP_R" | stats)"
    done
done
echo "# fine $(date -Is) carico: $(cut -d' ' -f1-3 /proc/loadavg)"
