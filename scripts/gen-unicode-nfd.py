#!/usr/bin/env python3
"""Genera src/unicode_nfd_data.zig: i dati per la decomposizione canonica (NFD).

Fonte: il modulo `unicodedata` di Python (nessun download). Due tabelle:
- per ogni carattere con una decomposizione canonica (Hangul escluso: è algoritmica)
  la sua NFD completa, già ricorsiva e ordinata;
- le classi di combinazione canoniche diverse da zero, a intervalli.
NFD(s) = concatenazione delle NFD dei caratteri, poi riordino canonico.

Uso: python3 scripts/gen-unicode-nfd.py | zig fmt --stdin > src/unicode_nfd_data.zig
"""
import sys
import unicodedata

MAX_CP = 0x10FFFF
HANGUL_S_BASE, HANGUL_S_COUNT = 0xAC00, 11172


def is_surrogate(cp):
    return 0xD800 <= cp <= 0xDFFF


keys, offsets, values = [], [0], []
max_len = 1
for cp in range(MAX_CP + 1):
    if is_surrogate(cp) or HANGUL_S_BASE <= cp < HANGUL_S_BASE + HANGUL_S_COUNT:
        continue
    ch = chr(cp)
    d = unicodedata.normalize("NFD", ch)
    if d == ch:
        continue
    keys.append(cp)
    values.extend(ord(c) for c in d)
    offsets.append(len(values))
    max_len = max(max_len, len(d))

# Caratteri ASCII che sono la NFD di un carattere non ASCII (U+037E → ";", U+1FEF → "`",
# U+212A → "K"): un nome tutto ASCII che li contiene può avere un equivalente non ASCII.
ascii_targets = sorted({unicodedata.normalize("NFD", chr(k)) for k in keys if all(ord(c) < 0x80 for c in unicodedata.normalize("NFD", chr(k)))})
assert all(len(t) == 1 for t in ascii_targets)

ranges = []  # (primo, ultimo, classe)
for cp in range(MAX_CP + 1):
    if is_surrogate(cp):
        continue
    c = unicodedata.combining(chr(cp))
    if c == 0:
        continue
    if ranges and ranges[-1][1] == cp - 1 and ranges[-1][2] == c:
        ranges[-1][1] = cp
    else:
        ranges.append([cp, cp, c])


def emit(name, typ, items, per_line=12):
    out = [f"pub const {name} = [_]{typ}{{"]
    for i in range(0, len(items), per_line):
        out.append("    " + ", ".join(items[i : i + per_line]) + ",")
    out.append("};")
    return "\n".join(out)


print(f"""//! GENERATO da scripts/gen-unicode-nfd.py (Unicode {unicodedata.unidata_version}): non modificare a mano.
//! Decomposizione canonica completa per carattere (Hangul escluso, è algoritmica) e
//! classi di combinazione canoniche. Vedi src/unicode_path.zig.

/// Lunghezza massima, in caratteri, della NFD di un singolo carattere (Hangul: 3).
pub const max_decomposition_len = {max(max_len, 3)};

/// Caratteri con decomposizione canonica, in ordine crescente.""")
print(emit("decomp_keys", "u21", [f"0x{k:X}" for k in keys]))
print("\n/// `decomp_values[decomp_offsets[i]..decomp_offsets[i + 1]]` è la NFD di `decomp_keys[i]`.")
print(emit("decomp_offsets", "u16", [str(o) for o in offsets], 16))
print()
print(emit("decomp_values", "u21", [f"0x{v:X}" for v in values]))
print("\n/// Classi di combinazione diverse da zero: intervalli `[primo, ultimo]` crescenti.")
print("pub const Ccc = struct { first: u21, last: u21, class: u8 };")
print(emit("ccc_ranges", "Ccc", [f".{{ .first = 0x{a:X}, .last = 0x{b:X}, .class = {c} }}" for a, b, c in ranges], 3))
zig_str = "".join("\\x%02x" % ord(t) for t in ascii_targets)
print(f"\n/// Caratteri ASCII che sono la NFD di un carattere non ASCII.\npub const ascii_nfd_targets = \"{zig_str}\";")
print(f"\n/// Versione Unicode dei dati.\npub const unicode_version = \"{unicodedata.unidata_version}\";")
