#!/usr/bin/env python3
"""Generate inert library-editing inputs; optionally serve artwork on loopback.

Does not install files, edit a simulator, launch an app, or generate runnable code.
"""
import argparse
import hashlib
import http.server
import json
from pathlib import Path
import struct
import zlib

TITLE = "ICube Library Edit Audit NEVER LAUNCH"


def png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    # Small solid-magenta/black stripes make the rendered preview unambiguous.
    rows = b"".join(b"\0" + b"".join(bytes((255, 0, 255)) if (x // 4 + y // 4) % 2 else bytes(3)
                                  for x in range(32)) for y in range(32))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 32, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="scratch fixture output directory")
    parser.add_argument("--serve", action="store_true", help="serve loopback artwork until interrupted")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    # Not a DOL header, ELF, ROM, or executable; GameFile.cpp accepts .dol by extension.
    marker = b"INERT ICUBE LIBRARY METADATA AUDIT ONLY - NEVER LAUNCH\n".ljust(64, b"!")
    files = {TITLE + ".dol": marker, "audit-cover.png": png()}
    for name, data in files.items():
        (args.output / name).write_bytes(data)
    print(json.dumps({name: {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                      for name, data in files.items()}, indent=2), flush=True)
    if not args.serve:
        return

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/audit-cover.png":
                data = files["audit-cover.png"]
                self.send_response(200)
                self.send_header("Content-Type", "image/png")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            elif self.path in ("/oversized.png", "/oversized-stream.png"):
                size = 12 * 1024 * 1024 + 1
                self.send_response(200)
                self.send_header("Content-Type", "image/png")
                if self.path == "/oversized.png":
                    self.send_header("Content-Length", str(size))
                self.send_header("Connection", "close")
                self.end_headers()
                try:
                    while size:
                        count = min(size, 65536)
                        self.wfile.write(b"X" * count)
                        size -= count
                except (BrokenPipeError, ConnectionResetError):
                    pass  # Expected when the bounded reader rejects the response.
            else:
                self.send_error(404)

    print(f"Artwork fixtures: http://127.0.0.1:{args.port}/audit-cover.png", flush=True)
    http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
