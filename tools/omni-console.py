#!/usr/bin/env python3
"""Drive the Omni serial console (exposed over TCP by a jumphost) non-interactively.

A serial console is the only way into this box when it has no network -- and the
measured unit has none (eth0 is UP but NO-CARRIER; only lo has an address). An
interactive `socat -,raw,echo=0 TCP:host:port` session cannot be scripted, hence
this.

Usage:
  omni-console.py listen [--secs N]
  omni-console.py send "<cmd>" [--quiet S] [--timeout T] [--no-newline]
  omni-console.py raw  "<hex>"          # raw bytes, e.g. 0a (LF) or 03 (Ctrl-C)

Target:
  OMNI_CONSOLE_HOST=<ip> OMNI_CONSOLE_PORT=<port> tools/omni-console.py send "uname -a"
  (or --host/--port)

Reads until the link has been idle for --quiet seconds, or --timeout total.
It sends exactly what you ask for and nothing else: no auto-retry, no newline
you did not request, no writes of any kind.

Two things that will bite you on this device:

  * The stock image's shell is zsh with its line editor active, so the command is
    echoed back interleaved with cursor-redraw escapes. Parse the OUTPUT, not the
    echo.
  * Anything you intend to decode needs explicit markers, and you must take the
    text after the LAST marker -- the first occurrence is the shell echoing your
    own command. Long single-line output does not survive the console; let base64
    wrap normally. See the recipe in docs/HARDWARE-MEASURED.md.
"""
import argparse
import os
import socket
import sys
import time

HOST = os.environ.get("OMNI_CONSOLE_HOST", "127.0.0.1")
PORT = int(os.environ.get("OMNI_CONSOLE_PORT", "4445"))


def drain(sock, quiet, timeout):
    """Read until idle for `quiet` seconds, or `timeout` total elapsed."""
    buf = b""
    start = last = time.monotonic()
    sock.settimeout(0.3)
    while True:
        now = time.monotonic()
        if now - start > timeout:
            break
        if buf and (now - last) > quiet:
            break
        if not buf and (now - start) > min(timeout, quiet * 3):
            break
        try:
            chunk = sock.recv(8192)
            if not chunk:
                break
            buf += chunk
            last = time.monotonic()
        except socket.timeout:
            continue
        except OSError as exc:
            sys.stderr.write(f"[recv error: {exc}]\n")
            break
    return buf


def main():
    ap = argparse.ArgumentParser(description="Non-interactive Omni serial console driver.")
    ap.add_argument("mode", choices=["listen", "send", "raw"])
    ap.add_argument("payload", nargs="?", default="")
    ap.add_argument("--secs", type=float, default=10.0, help="listen duration")
    ap.add_argument("--quiet", type=float, default=2.0, help="idle seconds that end a read")
    ap.add_argument("--timeout", type=float, default=25.0, help="hard cap on one exchange")
    ap.add_argument("--no-newline", action="store_true")
    ap.add_argument("--host", default=HOST)
    ap.add_argument("--port", type=int, default=PORT)
    args = ap.parse_args()

    with socket.create_connection((args.host, args.port), timeout=10) as sock:
        if args.mode == "listen":
            out = drain(sock, quiet=args.secs, timeout=args.secs)
        else:
            if args.mode == "raw":
                data = bytes.fromhex(args.payload.replace(" ", ""))
            else:
                data = args.payload.encode()
                if not args.no_newline:
                    data += b"\n"
            # Soak up anything already queued so the reply is not mixed with backlog.
            drain(sock, quiet=0.4, timeout=2.0)
            sock.sendall(data)
            out = drain(sock, quiet=args.quiet, timeout=args.timeout)

    sys.stdout.write(out.decode("utf-8", errors="replace"))
    sys.stdout.flush()


if __name__ == "__main__":
    main()
