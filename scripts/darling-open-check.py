#!/usr/bin/env python3
"""Prova sotto Darling l'apertura dei documenti come dal Finder: `open -a Zuer.app file…`.

Il percorso passa da LaunchServices (Apple Event kAEOpenDocuments), AppKit
(`application:openURLs:`), Zicro (`on_open_file`) e arriva a Zuer, che lo apre. Ogni file
di prova è un PNG di dimensioni diverse: la traccia di Zuer (`ZUER_TRACE`, una riga al
secondo con `static=LxA file=nome`) dice quale file è stato davvero decodificato e
mostrato, non solo che l'evento è arrivato. Un caso passa quando una riga ha le
dimensioni del file atteso, il suo nome com'è sul disco e almeno un frame disegnato.

Darling decompone gli accenti degli URL (NFD, come macOS) ma gira su un filesystem Linux,
che confronta i byte: un nome salvato composto (NFC) arriva in una forma che sul disco non
esiste. È il caso che `src/unicode_path.zig` risolve.

Requisiti: Darling con LaunchServices che consegna kAEOpenDocuments e un AppKit che lo
passa al delegate (darlinghq/darling e darling-cocotron, "open documents"); un Zuer.app
x86_64 (`scripts/build-macos-bundle.sh --arch x86_64`).

Uso: python3 -I scripts/darling-open-check.py <Zuer.app> [--out DIR] [--only caso,…]

Per leggere la traccia anche quando LaunchServices avvia l'app (stdio su /dev/null) si usa
una copia del bundle il cui eseguibile è uno script che imposta le variabili di traccia e
fa `exec` di `zuer-gui` con l'uscita su un file: binario e consegna restano gli stessi.
"""
import argparse
import os
import plistlib
import re
import shutil
import signal
import struct
import subprocess
import sys
import time
import unicodedata
import zlib

SYSROOT = "/Volumes/SystemRoot"
NFC = lambda s: unicodedata.normalize("NFC", s)
NFD = lambda s: unicodedata.normalize("NFD", s)


def png(path, w, h, rgb):
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))

    row = b"\x00" + bytes(rgb) * w
    data = zlib.compress(row * h, 6)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", data) + chunk(b"IEND", b""))


class Case:
    def __init__(self, name, sent, expect=None, cold=False, error=None, note=""):
        self.name, self.sent, self.expect, self.cold, self.error, self.note = name, sent, expect, cold, error, note


def make_files(d):
    """Crea i file di prova; ritorna {chiave: (percorso su disco, (w, h))}."""
    if os.path.exists(d):
        shutil.rmtree(d)
    os.makedirs(d)
    files = {}

    def add(key, rel, w, h, rgb=(200, 80, 40)):
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        png(p, w, h, rgb)
        files[key] = (p, (w, h))

    add("ascii", "ascii.png", 301, 201)
    add("nfc", NFC("città.png"), 302, 202)  # salvato composto: il caso di Linux
    add("nfd_disk", NFD("caffè.png"), 303, 203)  # salvato decomposto, come da macOS
    add("dir", NFC("cartella è/dentro ò.png"), 304, 204)  # cartella e file accentati
    add("ja", NFC("データ.png"), 305, 205)  # デ = テ + U+3099 in NFD
    add("ko", NFC("한국어.png"), 306, 206)  # Hangul: decomposizione algoritmica
    add("greek", "domanda\u037e.png", 318, 218)  # U+037E: la sua NFD è ";", ASCII
    add("multi_a", "multi a.png", 307, 207)
    add("multi_b", NFC("multi è.png"), 308, 208)
    add("multi_c", "multi c.png", 309, 209)
    add("second", "secondo.png", 311, 211)  # ASCII: misura solo la concorrenza
    add("big", "grande.png", 7000, 7000)  # tiene occupato il loader
    # Due file con nomi canonicamente equivalenti ma byte diversi (su Linux possono
    # coesistere): ậ composto e a + U+0302 + U+0323 (ordine non canonico). L'URL arriva
    # in NFD canonica (a + U+0323 + U+0302), che non coincide con nessuno dei due.
    add("amb1", "x ậ.png", 312, 212)
    add("amb2", "x ậ.png", 313, 213)
    files["missing"] = (os.path.join(d, NFC("manca è.png")), None)
    # Cache degli errori: in ogni cartella un solo file (nessun vicino, quindi il
    # prefetch non svuota la cache); il secondo file si crea durante la prova.
    add("cache_a", "cache/a.png", 314, 214)
    files["cache_z"] = (os.path.join(d, "cache", "z.png"), (315, 215))
    add("cacheu_a", "cache-u/a.png", 316, 216)
    files["cacheu_z"] = (os.path.join(d, "cache-u", NFD("zeta è.png")), (317, 217))
    return files


def wrapper_bundle(app, out, log):
    dst = os.path.join(out, "ZuerTrace.app")
    if os.path.exists(dst):
        shutil.rmtree(dst)
    shutil.copytree(app, dst, symlinks=True)
    macos = os.path.join(dst, "Contents", "MacOS")
    script = os.path.join(macos, "zuer-trace")
    with open(script, "w") as f:
        f.write("#!/bin/sh\nexport ZUER_TRACE=1 ZICRO_COCOA_TRACE=1 ZUER_NO_CRASH_REPORT=1\n")
        f.write(f'exec "$(dirname "$0")/zuer-gui" "$@" >>"{SYSROOT}{log}" 2>&1\n')
    os.chmod(script, 0o755)
    plist = os.path.join(dst, "Contents", "Info.plist")
    with open(plist, "rb") as f:
        info = plistlib.load(f)
    info["CFBundleExecutable"] = "zuer-trace"
    info["CFBundleIdentifier"] = "test.zuer.darling-open-check"
    # Il bundle originale può essere firmato: la firma non vale più per la copia.
    shutil.rmtree(os.path.join(dst, "Contents", "_CodeSignature"), ignore_errors=True)
    with open(plist, "wb") as f:
        plistlib.dump(info, f)
    return dst


def zuer_pids():
    """Solo i processi del bundle di prova (mai un altro Zuer aperto sull'host)."""
    pids = []
    for e in os.listdir("/proc"):
        if not e.isdigit():
            continue
        try:
            with open(f"/proc/{e}/cmdline", "rb") as f:
                cmd = f.read()
        except OSError:
            continue
        if b"ZuerTrace.app/Contents/MacOS/zuer-gui" in cmd:
            pids.append(int(e))
    return pids


def kill_zuer():
    """Chiude per PID (sotto Darling `timeout` non basta) i soli processi di prova."""
    for p in zuer_pids():
        try:
            os.kill(p, signal.SIGKILL)
        except ProcessLookupError:
            pass
    for _ in range(50):
        if not zuer_pids():
            return
        time.sleep(0.1)


def darling_open(app, paths):
    cmd = ["darling", "shell", "open", "-a", SYSROOT + app] + [SYSROOT + p for p in paths]
    return subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, timeout=90)


TRACE = re.compile(rb"\[trace\] ticks=\d+ renders=(\d+) .* static=(\d+)x(\d+) .* file=(.*)$")


def wait_trace(log, start, pred, timeout):
    """Attende una riga di traccia, scritta dopo `start`, per cui pred(renders, w, h, name)."""
    end = time.time() + timeout
    while time.time() < end:
        with open(log, "rb") as f:
            f.seek(start)
            for line in f.read().splitlines():
                m = TRACE.search(line)
                if m and pred(int(m[1]), int(m[2]), int(m[3]), m[4]):
                    return True
        time.sleep(0.25)
    return False


def log_since(log, start):
    with open(log, "rb") as f:
        f.seek(start)
        return f.read()


def shown(files, key):
    path, (w, h) = files[key]
    name = os.path.basename(path).encode()
    return lambda r, sw, sh, n: sw == w and sh == h and n == name and r > 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("app")
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "zig-out", "tmp", "darling-open"))
    ap.add_argument("--only", default="")
    args = ap.parse_args()
    app = os.path.abspath(args.app)
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    log = os.path.join(out, "zuer.log")
    open(log, "wb").close()
    files = make_files(os.path.join(out, "file"))
    tapp = wrapper_bundle(app, out, log)
    subprocess.run(["darling", "shell", "true"], stdin=subprocess.DEVNULL, capture_output=True, timeout=120)

    results = []

    def record(name, ok, detail=""):
        results.append((name, ok))
        print(f"{'PASS' if ok else 'FAIL'}: {name}{' — ' + detail if detail else ''}", flush=True)

    def ensure_running():
        if zuer_pids():
            return True
        start = os.path.getsize(log)
        darling_open(tapp, [])
        return wait_trace(log, start, lambda *a: True, 60)

    def open_case(name, keys, sent_forms=None, cold=False, expect=None, timeout=60):
        """Manda `keys` (in un solo `open -a`) e attende che `expect` sia mostrato."""
        if cold:
            kill_zuer()
        elif not ensure_running():
            record(name, False, "Zuer non parte")
            return None
        start = os.path.getsize(log)
        paths = [files[k][0] for k in keys]
        r = darling_open(tapp, paths)
        if r.returncode != 0:
            record(name, False, f"open -a: {r.returncode} {r.stderr.decode(errors='replace').strip()}")
            return start
        ok = wait_trace(log, start, shown(files, expect), timeout)
        detail = ""
        if not ok:
            text = log_since(log, start)
            detail = (f"atteso {os.path.basename(files[expect][0])!r} {files[expect][1]}; open -a rc={r.returncode}, "
                      f"consegne={text.count(b'open file:')}, righe di traccia={text.count(b'[trace]')}, processi={len(zuer_pids())}")
        record(name, ok, detail)
        return start

    only = set(filter(None, args.only.split(",")))
    want = lambda c: not only or c in only

    for key, label in [("ascii", "ASCII"), ("nfc", "NFC su disco"), ("nfd_disk", "NFD su disco")]:
        for cold in (True, False):
            name = f"{label}, {'cold launch' if cold else 'Zuer già aperto'}"
            if want(key):
                open_case(name, [key], cold=cold, expect=key)
    if want("dir"):
        open_case("cartella con accenti", ["dir"], expect="dir")
    if want("ja"):
        open_case("nome giapponese (デ decomposta)", ["ja"], expect="ja")
    if want("ko"):
        open_case("nome coreano (Hangul)", ["ko"], expect="ko")

    if want("greek"):
        open_case("punto interrogativo greco (NFD in ASCII)", ["greek"], expect="greek")

    if want("missing"):
        ensure_running()
        start = os.path.getsize(log)
        darling_open(tapp, [files["missing"][0]])
        name = os.path.basename(files["missing"][0])
        # Il messaggio è testo disegnato: la riga ha il nome chiesto e un frame, nessuna
        # delle dimensioni dei PNG di prova.
        sizes = {v[1] for v in files.values() if v[1]}
        got = wait_trace(log, start, lambda r, w, h, n: NFC(n.decode(errors="replace")) == name and r > 0 and (w, h) not in sizes, 30)
        msg = b"file dal sistema illeggibile" in log_since(log, start) and b"FileNotFound" in log_since(log, start)
        record("file inesistente: messaggio d'errore al posto del contenuto", got and msg)

    def cache_case(name, a, z):
        """Errore su `z` (inesistente), poi un altro file, poi `z` creato e riaperto: si
        deve vedere `z`, non l'errore di prima rimasto in cache."""
        zpath, zdims = files[z]
        if os.path.exists(zpath):
            os.remove(zpath)
        # Istanza fresca: con la cache di prefetch già piena (4 voci) l'errore non
        # verrebbe parcheggiato comunque e la prova passerebbe anche col difetto.
        kill_zuer()
        if not ensure_running():
            record(name, False, "Zuer non parte")
            return
        sizes = {v[1] for v in files.values() if v[1]}
        zname = NFC(os.path.basename(zpath))
        start = os.path.getsize(log)
        darling_open(tapp, [zpath])
        err = wait_trace(log, start, lambda r, w, h, n: NFC(n.decode(errors="replace")) == zname and r > 0 and (w, h) not in sizes, 30)
        start = os.path.getsize(log)
        darling_open(tapp, [files[a][0]])
        other = wait_trace(log, start, shown(files, a), 30)
        png(zpath, *zdims, (40, 160, 90))
        start = os.path.getsize(log)
        darling_open(tapp, [zpath])
        ok = wait_trace(log, start, shown({"z": (zpath, zdims)}, "z"), 30)
        # E ci resta: nessuna riga successiva torna al messaggio.
        time.sleep(3)
        lines = [TRACE.search(l) for l in log_since(log, start).splitlines()]
        dims = [(int(m[2]), int(m[3])) for m in lines if m]
        stays = zdims in dims and all(d == zdims for d in dims[dims.index(zdims):])
        record(name, err and other and ok and stays, "" if ok else "si vede ancora l'errore di prima")

    if want("cache"):
        cache_case("errore in cache: file creato dopo e riaperto si vede", "cache_a", "cache_z")
    if want("cacheu"):
        cache_case("errore in cache, nome Unicode: file creato dopo e riaperto si vede", "cacheu_a", "cacheu_z")

    if want("amb"):
        ensure_running()
        start = os.path.getsize(log)
        darling_open(tapp, [files["amb1"][0]])
        time.sleep(4)
        text = log_since(log, start)
        no_pick = not wait_trace(log, start, lambda r, w, h, n: (w, h) in (files["amb1"][1], files["amb2"][1]), 1)
        record("nomi equivalenti ambigui: nessuna scelta, errore", b"AmbiguousName" in text and no_pick)

    if want("multi"):
        # Zuer mostra un documento alla volta: di un evento con più file li apre tutti
        # in ordine (ognuno passa da `openFromSystem`, il caricamento è latest-wins) e
        # resta sull'ultimo; le frecce scorrono poi la sua cartella.
        keys = ["multi_a", "multi_b", "multi_c"]
        start = open_case("tre documenti in un solo evento: si vede l'ultimo", keys, expect="multi_c")
        if start is not None:
            text = NFC(log_since(log, start).decode(errors="replace"))
            delivered = all(f"open file: {SYSROOT}{NFC(files[k][0])}" in text for k in keys)
            record("tre documenti in un solo evento: tutti consegnati a Zuer, in ordine", delivered and
                   text.index(NFC(files["multi_a"][0])) < text.index(NFC(files["multi_b"][0])) < text.index(NFC(files["multi_c"][0])))
            time.sleep(2)
            dims = [(int(m[2]), int(m[3])) for m in map(TRACE.search, log_since(log, start).splitlines()) if m]
            last = files["multi_c"][1]
            record("tre documenti in un solo evento: nessun altro sopra l'ultimo", last in dims and all(d == last for d in dims[dims.index(last):]))
        # Un file mancante in mezzo non ferma gli altri: si vede comunque l'ultimo.
        # Prima un altro file, così l'ultimo dell'evento non è già quello mostrato.
        open_case("(preparazione: un altro file)", ["ascii"], expect="ascii")
        start = open_case("evento con un file mancante in mezzo: si vede l'ultimo", ["multi_a", "missing", "multi_c"], expect="multi_c")
        if start is not None:
            text = NFC(log_since(log, start).decode(errors="replace"))
            record("evento con un file mancante in mezzo: il mancante è segnalato", f"illeggibile: {SYSROOT}{NFC(files['missing'][0])}" in text)

    if want("busy"):
        # Il secondo Apple Event arriva mentre il loader decodifica il PNG grande: deve
        # vincere il più recente, e il grande non deve comparire dopo.
        ensure_running()
        start = os.path.getsize(log)
        darling_open(tapp, [files["big"][0]])
        darling_open(tapp, [files["second"][0]])
        ok = wait_trace(log, start, shown(files, "second"), 60)
        time.sleep(3)
        lines = [TRACE.search(l) for l in log_since(log, start).splitlines()]
        dims = [(int(m[2]), int(m[3])) for m in lines if m]
        after = dims[dims.index(files["second"][1]):] if files["second"][1] in dims else []
        record("secondo Apple Event mentre Zuer è occupato: vince il più recente", ok and files["big"][1] not in after)

    kill_zuer()
    failed = [n for n, ok in results if not ok]
    if failed:
        keep = log + time.strftime(".fallito-%H%M%S")
        shutil.copyfile(log, keep)
        print(f"traccia conservata: {keep}")
    print(f"\n{len(results) - len(failed)}/{len(results)} passati" + (f"; falliti: {', '.join(failed)}" if failed else ""))
    print(f"traccia: {log}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
