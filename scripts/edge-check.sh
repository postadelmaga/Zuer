#!/usr/bin/env bash
# File limite in apertura (§ audit): vuoti, troncati, estensione sbagliata, casuali,
# permessi, link rotti, cartelle, FIFO, molto grandi. Ogni caso deve dare un esito
# (contenuto o errore esplicito) entro 30 s, senza crash. Lanciato da `/`: i plugin
# si trovano accanto all'eseguibile, mai nella cartella corrente.
# Con WAYLAND_DISPLAY anche la GUI: una FIFO col nome di un video non deve finire
# aperta (prima mpv ci restava appeso e l'app non si chiudeva più). Muto.
#
#   scripts/edge-check.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
Z=$ROOT/zig-out/bin/zuer
W=$(mktemp -d); gp=
trap '[ -n "$gp" ] && kill $gp 2>/dev/null; chmod -R u+rwx "$W"; rm -rf "$W"' EXIT
cd "$W"
: > empty.txt; : > empty.png
printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR' > trunc.png
printf 'ciao\n' > wrongext.png
head -c 200000 /dev/urandom > random.bin
printf 'a,b\n1,2\n"x,3\n' > bad.csv
printf '\xff\xfe\x00\xd8 \xc3\x28\n' > badutf8.txt
printf 'PK\003\004garbage' > fake.zip; cp fake.zip fake.xlsx
printf 'v 0 0 0\nf 1 2 99\n' > bad.obj
printf 'glTF\x02\0\0\0\xff\xff\xff\x7f' > bad.glb
printf '%%PDF-1.4\ngarbage' > bad.pdf
python3 -c "open('long.txt','w').write(('x'*200000+'\n')*3)"
python3 -c "
l=b'riga di testo per riempire il file 0123456789\n'; open('big.txt','wb').write(l*(300*1024*1024//len(l)))"
mkdir dir; ln -s nonexist broken; mkfifo fifo.txt; mkfifo fifo.mp4
touch noperm.txt; chmod 000 noperm.txt
fail=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FALLITO: $1"; fail=1; fi; }
for f in empty.txt empty.png trunc.png wrongext.png random.bin bad.csv badutf8.txt fake.zip fake.xlsx bad.obj bad.glb bad.pdf long.txt big.txt dir broken fifo.txt fifo.mp4 noperm.txt "$W/nonexist"; do
    t0=$(date +%s%N)
    (cd / && timeout 30 "$Z" --json "$W/$f" > "$W/out" 2> "$W/err"); rc=$?
    ms=$(( ($(date +%s%N) - t0) / 1000000 ))
    kind=$(head -c 200 "$W/out" | grep -oE '"type":"[a-z]+"' | head -1)
    check "$f: esito ${kind:-nessuno} in $ms ms (rc=$rc)" "[ $rc = 0 ] && [ -n '$kind' ]"
done
# Ogni invocazione con un tetto: un caso che si appende non deve appendere lo script.
json() { (cd / && timeout 30 "$Z" --json "$W/$1"); }
check "empty.txt è testo vuoto, non un errore" "json empty.txt | grep -q '\"type\":\"text\"'"
check "fifo.txt rifiutata come file non regolare" "json fifo.txt | grep -q 'Non è un file regolare'"
check "plugin trovati lanciando da /" "json bad.csv | grep -q '\"type\":\"csv\"'"
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    ZUER_MPV_OPTS=ao=null "$ROOT/zig-out/bin/zuer-gui" "$W/fifo.mp4" > "$W/gui.log" 2>&1 &
    gp=$!; sleep 3
    held=$(ls -l /proc/$gp/fd 2>/dev/null | grep -c 'fifo.mp4')
    # SIGKILL: con un player appeso la GUI non uscirebbe al TERM (è il difetto cercato).
    kill -9 $gp 2>/dev/null; wait $gp 2>/dev/null; gp=
    check "GUI: la FIFO .mp4 non viene aperta (fd tenuti: $held)" "[ $held = 0 ]"
fi
exit $fail
