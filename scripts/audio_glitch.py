#!/usr/bin/env python3
"""Analizza una registrazione di un tono sinusoidale puro e conta le discontinuità.

  audio_glitch.py FILE.raw FREQ [T0_MONOTONIC] [EVENTI]

FILE.raw: float32le stereo 48 kHz (es. `parec --raw --format=float32le` dal
monitor di un sink). Un seno puro soddisfa x[n] = 2cos(w)·x[n-1] - x[n-2]: il
residuo di quella ricorrenza è ~0 (salvo la quantizzazione del codec) e salta a
ogni click, pop, buco o ripresa sfasata. Riporta:
  * buchi: tratti di silenzio ≥ 5 ms dopo l'inizio del tono (underrun, stalli);
  * click: discontinuità di fase/ampiezza fuori dai buchi;
  * ampiezza e frequenza misurate (deriva del clock: frequenza ≠ FREQ).
Con T0 (istante monotono dell'inizio registrazione) ed EVENTI (file con righe
"istante_monotono etichetta") ogni anomalia viene attribuita all'evento più
vicino nei 400 ms precedenti (seek, pausa, cambio sorgente…): quelle sono attese,
le altre no.
"""
import sys

import numpy as np

RATE = 48000
raw = np.fromfile(sys.argv[1], dtype="<f4")
freq = float(sys.argv[2])
t0 = float(sys.argv[3]) if len(sys.argv) > 3 else None
events = []
if len(sys.argv) > 4:
    for ln in open(sys.argv[4]):
        p = ln.split(None, 1)
        if len(p) == 2:
            events.append((float(p[0]), p[1].strip()))

x = raw[0::2].astype(np.float64)
n = len(x)
if n < RATE // 10:
    print("glitch: registrazione troppo corta")
    sys.exit(1)

amp = np.abs(x)
# Inviluppo su finestre di 1 ms: un ciclo intero a 1 kHz.
win = RATE // 1000
env = amp[: n // win * win].reshape(-1, win).max(axis=1)
on = env > 0.01
if not on.any():
    print("glitch: nessun tono nella registrazione")
    sys.exit(1)
first = int(np.argmax(on))
last = len(on) - int(np.argmax(on[::-1])) - 1

gaps = []
i = first
while i <= last:
    if not on[i]:
        j = i
        while j <= last and not on[j]:
            j += 1
        if j - i >= 5:
            gaps.append((i * win, (j - i)))
        i = j
    else:
        i += 1

w = 2 * np.pi * freq / RATE
r = x[2:] - 2 * np.cos(w) * x[1:-1] + x[:-2]
level = np.median(env[first : last + 1][on[first : last + 1]])
thr = max(0.08 * level, 1e-3)
bad = np.nonzero(np.abs(r) > thr)[0] + 2
gap_mask = np.zeros(n, dtype=bool)
for s, l in gaps:
    gap_mask[max(0, s - 2 * win) : min(n, s + (l + 2) * win)] = True
clicks = []
last_c = -RATE
for b in bad:
    if b < first * win or b > (last + 1) * win or gap_mask[b]:
        continue
    if amp[b - 2 : b + 2].max() < 0.01:
        continue
    if b - last_c > RATE // 100:
        clicks.append(b)
    last_c = b

# Frequenza dal conteggio degli zeri sul tratto attivo più lungo.
bounds = [first * win] + [b for s, l in gaps for b in (s, s + l * win)] + [(last + 1) * win]
pairs = list(zip(bounds[0::2], bounds[1::2]))
a, b = max(pairs, key=lambda p: p[1] - p[0])
seg = x[a:b]
zc = np.nonzero((seg[:-1] < 0) & (seg[1:] >= 0))[0]
mfreq = (len(zc) - 1) / ((zc[-1] - zc[0]) / RATE) if len(zc) > 2 else 0


def who(sample):
    if first * win <= sample < first * win + RATE // 10:
        return "(avvio del tono)"
    for s, l in gaps:
        if s + l * win <= sample < s + l * win + RATE // 10:
            return "(ripresa dopo il buco)"
    if t0 is None or not events:
        return ""
    t = t0 + sample / RATE
    best = None
    for et, lab in events:
        if et <= t + 0.05 and t - et <= 0.4:
            best = lab
    return best or ""


exp_g = sum(1 for s, l in gaps if who(s))
exp_c = sum(1 for c in clicks if who(c))
print("glitch: durata_s=%.1f inizio_tono_s=%.3f tono_s=%.1f livello=%.3f freq_misurata=%.2f Hz" % (n / RATE, first * win / RATE, (last - first) * win / RATE, level, mfreq))
print("glitch: buchi=%d (attesi su evento %d, inattesi %d)  click=%d (attesi %d, inattesi %d)" % (
    len(gaps), exp_g, len(gaps) - exp_g, len(clicks), exp_c, len(clicks) - exp_c))
for s, l in gaps:
    print("  buco a %.3f s lungo %d ms %s" % (s / RATE, l, who(s)))
for c in clicks[:40]:
    print("  click a %.3f s residuo=%.3f %s" % (c / RATE, abs(r[c - 2]), who(c)))
