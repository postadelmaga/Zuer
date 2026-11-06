#!/usr/bin/env python3
"""Invarianti di protocollo su una traccia WAYLAND_DEBUG=client di zuer-gui:
 1. nessun wl_buffer riattaccato prima del suo release (slot del piano video
    riusati troppo presto); ricommit dello STESSO buffer consentito;
 2. ogni ack_configure conferma un serial ricevuto e non già superato;
 3. ogni dmabuf (create o create_immed) usa formato+modifier annunciati;
 4. nessun wl_display.error.
Stampa i conteggi (attach, release, attach null = piano nascosto, ...).
Esce con 1 se trova violazioni.

  WAYLAND_DEBUG=client zuer-gui clip.mp4 2> traccia.log
  scripts/wayland_check.py traccia.log
"""
import re, sys
L = re.compile(r'\] \{[^}]*\}\s+(->)?\s*([a-z_0-9]+)#(\d+)\.([a-z_]+)\((.*)\)\s*$')
busy = {}; pending = {}; announced = set(); params_mod = {}; current = {}
cfg = []; acked = -1; bad = []; n = {'attach': 0, 'release': 0, 'null': 0, 'dmabuf': 0, 'ack': 0, 'ricommit': 0}
for ln in open(sys.argv[1], errors='replace'):
    m = L.search(ln)
    if not m: continue
    req, iface, oid, meth, args = m.groups(); key = f'{iface}#{oid}'
    if iface == 'wl_display' and meth == 'error': bad.append('errore di protocollo: ' + ln.strip())
    if iface == 'zwp_linux_dmabuf_v1' and meth == 'modifier':
        f, hi, lo = map(int, args.split(', ')); announced.add((f, (hi << 32) | lo))
    if iface == 'zwp_linux_buffer_params_v1' and meth == 'add':
        a = args.split(', '); params_mod[key] = (int(a[4]) << 32) | int(a[5])
    if iface == 'zwp_linux_buffer_params_v1' and meth == 'create' and req:
        a = args.split(', ')
        fm = (int(a[2]), params_mod.get(key, -1))
        if announced and fm not in announced: bad.append(f'formato non annunciato {fm} per {key}.create')
    if iface == 'zwp_linux_buffer_params_v1' and meth == 'create_immed':
        a = re.match(r'new id wl_buffer#(\d+), (\d+), (\d+), (\d+), (\d+)', args)
        b = 'wl_buffer#' + a[1]; busy.pop(b, None); n['dmabuf'] += 1
        fm = (int(a[4]), params_mod.get(key, -1))
        if announced and fm not in announced: bad.append(f'formato non annunciato {fm} per {b}')
    if iface == 'wl_surface' and meth == 'attach' and req:
        b = args.split(',')[0].strip(); n['attach'] += 1
        if b == 'nil': n['null'] += 1; pending[key] = None
        else:
            # Ricommit del buffer già attaccato (stesso contenuto, es. nuova posizione
            # o viewport): consentito. Violazione = un ALTRO buffer ancora tenuto.
            if busy.get(b) and current.get(key) == b: n['ricommit'] += 1
            elif busy.get(b): bad.append(f'{b} riattaccato a {key} prima del release: ' + ln.split(']')[0] + ']')
            pending[key] = b
    if iface == 'wl_surface' and meth == 'commit' and req and key in pending:
        b = pending.pop(key)
        current[key] = b
        if b: busy[b] = True
    if iface == 'wl_buffer' and meth == 'release': busy[key] = False; n['release'] += 1
    if iface == 'wl_buffer' and meth == 'destroy': busy.pop(key, None)
    if iface == 'xdg_surface' and meth == 'configure': cfg.append(int(args))
    if iface == 'xdg_surface' and meth == 'ack_configure':
        s = int(args); n['ack'] += 1
        if s not in cfg or s <= acked: bad.append(f'ack_configure({s}) non valido (ricevuti {cfg[-3:]}, ultimo ack {acked})')
        acked = s
print('wlcheck:', ' '.join(f'{k}={v}' for k, v in n.items()), f'formati_annunciati={len(announced)} violazioni={len(bad)}')
for b in bad[:20]: print('  ', b)
sys.exit(1 if bad else 0)
