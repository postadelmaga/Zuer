#!/usr/bin/env bash
# Benchmark della pipeline miniature: scenari alternati, uno per processo.
#   scripts/bench-thumbnails.sh <cartella> [round] [cache] [scenari...]
# cache: none (default, solo decode) | warm (cache su disco già piena, voci
#        negative comprese: i decode falliti risultano hit)
# Variabili: BIN (default ./zig-out/bin/bench-thumbnails), più quelle di
# bench_thumbnails.zig (ZUER_BENCH_FG, ZUER_BENCH_FG_SIGNAL, ...).
# Ogni esecuzione ha una HOME vuota: anche le cache interne dei plugin (render
# dei PDF, poster video) partono fredde. Ogni round ruota l'ordine degli scenari.
# Output: le righe key=value di ogni esecuzione, poi le mediane per scenario.
set -euo pipefail
dir=${1:?cartella}
rounds=${2:-3}
cache=${3:-none}
shift $(( $# < 3 ? $# : 3 ))
scen=("$@")
[ ${#scen[@]} -eq 0 ] && scen=(seq w1 w2 w3 w4 auto)
bin=${BIN:-./zig-out/bin/bench-thumbnails}
[ -x "$bin" ] || { echo "manca $bin: zig build" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cache_arg=none
if [ "$cache" = warm ]; then
  cache_arg=$work/thumbs
  mkdir -p "$cache_arg" "$work/home0"
  HOME=$work/home0 "$bin" "$dir" seq "$cache_arg" >/dev/null 2>&1   # riempie la cache
fi
out=$work/out
n=${#scen[@]}
for ((r = 0; r < rounds; r++)); do
  for ((k = 0; k < n; k++)); do
    s=${scen[$(((k + r) % n))]}
    h=$work/home_${r}_${k}; rm -rf "$h"; mkdir -p "$h"
    HOME=$h "$bin" "$dir" "$s" "$cache_arg" 2>/dev/null | grep -E '^(scenario=|perf )' | tee -a "$out" || true
    rm -rf "$h"
  done
done
python3 - "$out" "${scen[@]}" <<'PY'
import sys, statistics as st
rows=[]; perf={}
for l in open(sys.argv[1]):
    kv=dict(x.split('=',1) for x in l.split()[1:] if '=' in x) if l.startswith('perf ') else dict(x.split('=',1) for x in l.split() if '=' in x)
    if l.startswith('perf '): rows[-1].update({'p_'+k:v for k,v in kv.items() if k!='scenario'})
    else: rows.append(kv)
keys=['wall_ms','cpu_ms','sys_ms','child_cpu_ms','thr_per_s','mean_ms','p95_ms','qwait_mean_us','qwait_max_us','maxrss_mb','threads_peak','jobs_max','thumbs','failed','cache_hit','fg_alone_first_ms','fg_alone_ms','fg_during_first_ms','fg_during_ms','p_context_switches','p_cpu_migrations','p_cache_misses','p_instructions','p_cycles']
print('\nmediane per scenario ('+str(len(rows))+' esecuzioni)')
print('scenario '+' '.join(keys)+' hash')
def med(rs,k):
    v=[float(r[k]) for r in rs if r.get(k,'-')!='-']
    return ('%g' % st.median(v)) if v else '-'
for s in sys.argv[2:]:
    rs=[r for r in rows if r.get('scenario')==s]
    if rs: print(s+' '+' '.join(med(rs,k) for k in keys)+' '+','.join(sorted(set(r['hash'] for r in rs))))
PY
