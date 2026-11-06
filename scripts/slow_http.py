#!/usr/bin/env python3
"""Server HTTP di prova per la verifica di buffering e chiusura (net-check.sh).

Serve i file di una cartella con supporto Range, con un comportamento scelto dal
percorso dell'URL:

  /ok/FILE              normale
  /slow/BPS/FILE        a BPS byte/s (buffering prolungato se < bitrate)
  /stall/N/FILE         manda N byte del corpo, poi resta muto (connessione aperta)
  /drop/N/FILE          manda N byte del corpo, poi chiude la connessione (caduta)
  /hang/FILE            accetta la connessione e non risponde mai
  /stall-after/N/FILE   come /ok fino a N byte complessivi serviti su TUTTE le
                        richieste di quel file, poi ogni richiesta resta muta
                        (rete che si interrompe a metà riproduzione, anche dopo
                        le riconnessioni del client)

  slow_http.py CARTELLA PORTA
Solo su 127.0.0.1. Una riga di log per richiesta su stderr.
"""
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.abspath(sys.argv[1])
PORT = int(sys.argv[2])
served = {}
served_lock = threading.Lock()


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%.3f %s\n" % (time.monotonic(), fmt % args))

    def do_HEAD(self):
        self.handle_req(head=True)

    def do_GET(self):
        self.handle_req(head=False)

    def handle_req(self, head):
        parts = self.path.lstrip("/").split("/")
        mode = parts[0]
        arg = None
        if mode in ("slow", "stall", "drop", "stall-after"):
            arg = int(parts[1])
            name = "/".join(parts[2:])
        else:
            name = "/".join(parts[1:])
        if mode == "hang":
            time.sleep(3600)
            return
        path = os.path.join(ROOT, name)
        if not os.path.isfile(path):
            self.send_error(404)
            return
        size = os.path.getsize(path)
        start, end = 0, size - 1
        m = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("Range", ""))
        if m:
            if m.group(1):
                start = int(m.group(1))
            if m.group(2):
                end = min(int(m.group(2)), size - 1)
        if mode == "stall-after":
            with served_lock:
                if served.get(name, 0) >= arg:
                    self.log_message("stall-after: muto")
                    time.sleep(3600)
                    return
        self.send_response(206 if m else 200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if m:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        if head:
            return
        sent = 0
        chunk = 16384
        with open(path, "rb") as f:
            f.seek(start)
            left = end - start + 1
            t0 = time.monotonic()
            while left > 0:
                n = min(chunk, left)
                if mode in ("stall", "drop") and sent + n > arg:
                    n = arg - sent
                    if n > 0:
                        self.wfile.write(f.read(n))
                    if mode == "drop":
                        self.log_message("drop dopo %d byte", arg)
                        self.close_connection = True
                        return
                    self.log_message("stall dopo %d byte", arg)
                    self.wfile.flush()
                    time.sleep(3600)
                    return
                if mode == "stall-after":
                    with served_lock:
                        tot = served.get(name, 0)
                        if tot >= arg:
                            self.log_message("stall-after: muto a metà")
                            self.wfile.flush()
                            time.sleep(3600)
                            return
                        served[name] = tot + n
                data = f.read(n)
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    return
                sent += n
                left -= n
                if mode == "slow":
                    ahead = sent / arg - (time.monotonic() - t0)
                    if ahead > 0:
                        time.sleep(ahead)


class S(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


S(("127.0.0.1", PORT), H).serve_forever()
