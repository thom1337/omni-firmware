#!/usr/bin/env python3
"""Push files to the Omni over the serial console, with end-to-end verification.

The unit has no network (eth0 is UP but NO-CARRIER), so the console is the only
way to get anything onto it. This tars + gzips + base64s the payload, streams it
in chunks the console can survive, and then verifies the SHA-256 ON THE DEVICE
before extracting. A partial or corrupted transfer therefore fails loudly at the
digest instead of producing a half-written script that runs anyway -- which
matters, because the things being pushed write the device's only copy of its
U-Boot environment.

Usage:
  OMNI_CONSOLE_HOST=<ip> tools/omni-push.py --dest /data/omni-tools FILE [FILE ...]

Options
  --dest DIR       where to extract on the device (default /data/omni-tools).
                   Prefer /data (p3): it is 150 MiB and is NOT the per-slot
                   overlay upper, so a push does not dirty the running slot.
  --chunk N        base64 characters per write (default 512). The stock image's
                   zsh line editor redraws long lines; the echo looks mangled but
                   the shell receives them intact. Lower this if a digest fails.
  --keep-b64       leave the staged .b64 on the device for debugging
"""
import argparse
import base64
import hashlib
import io
import os
import socket
import sys
import tarfile
import time

HOST = os.environ.get("OMNI_CONSOLE_HOST", "127.0.0.1")
PORT = int(os.environ.get("OMNI_CONSOLE_PORT", "4445"))


def drain(sock, quiet=0.4, timeout=20.0):
    buf = b""
    start = last = time.monotonic()
    sock.settimeout(0.2)
    while True:
        now = time.monotonic()
        if now - start > timeout:
            break
        if buf and (now - last) > quiet:
            break
        if not buf and (now - start) > min(timeout, quiet * 4):
            break
        try:
            c = sock.recv(8192)
            if not c:
                break
            buf += c
            last = time.monotonic()
        except socket.timeout:
            continue
        except OSError:
            break
    return buf.decode("utf-8", "replace")


def run(sock, cmd, quiet=0.5, timeout=25.0):
    sock.sendall(cmd.encode() + b"\n")
    return drain(sock, quiet, timeout)


def main():
    ap = argparse.ArgumentParser(description="Push files to the Omni over serial.")
    ap.add_argument("files", nargs="+")
    ap.add_argument("--dest", default="/data/omni-tools")
    ap.add_argument("--chunk", type=int, default=512)
    ap.add_argument("--keep-b64", action="store_true")
    ap.add_argument("--host", default=HOST)
    ap.add_argument("--port", type=int, default=PORT)
    args = ap.parse_args()

    # Build the payload in memory: tar -> gzip -> base64.
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w:gz") as tf:
        for f in args.files:
            if not os.path.isfile(f):
                sys.stderr.write(f"not a file: {f}\n")
                return 2
            tf.add(f, arcname=os.path.basename(f))
    payload = raw.getvalue()
    digest = hashlib.sha256(payload).hexdigest()
    b64 = base64.b64encode(payload).decode()

    print(f"payload: {len(args.files)} file(s), {len(payload)} bytes gz, "
          f"{len(b64)} b64 chars, sha256 {digest[:16]}…", flush=True)

    stage = f"{args.dest}.tgz.b64"
    with socket.create_connection((args.host, args.port), timeout=10) as sock:
        sock.settimeout(0.2)
        drain(sock, 0.4, 3.0)

        out = run(sock, "id -un")
        if "root" not in out:
            sys.stderr.write("not at a root shell on the device; log in first\n")
            return 3

        run(sock, f"mkdir -p {args.dest} && rm -f {stage} && echo STAGE_READY")

        total = (len(b64) + args.chunk - 1) // args.chunk
        for i in range(total):
            piece = b64[i * args.chunk:(i + 1) * args.chunk]
            # base64 alphabet is [A-Za-z0-9+/=], so single-quoting is safe.
            run(sock, f"printf '%s' '{piece}' >> {stage}", quiet=0.25, timeout=15)
            if (i + 1) % 10 == 0 or i + 1 == total:
                print(f"  chunk {i+1}/{total}", flush=True)

        # Verify ON THE DEVICE before anything is extracted or executed.
        out = run(sock, f"base64 -d {stage} | sha256sum | cut -d' ' -f1", quiet=1.0, timeout=40)
        if digest not in out:
            sys.stderr.write(
                "\nDIGEST MISMATCH -- the transfer is corrupt.\n"
                f"  expected {digest}\n  device said: {out.strip()[:200]}\n"
                "  Nothing was extracted. Retry with a smaller --chunk.\n")
            return 4
        print(f"digest verified on device: {digest[:16]}…", flush=True)

        out = run(sock, f"base64 -d {stage} | tar xzf - -C {args.dest} && "
                        f"chmod +x {args.dest}/* 2>/dev/null; ls -1 {args.dest}",
                  quiet=1.0, timeout=40)
        print("extracted:", flush=True)
        for line in out.splitlines():
            s = line.strip()
            if s and not s.startswith("base64") and "tar xzf" not in s:
                print("   ", s, flush=True)

        if not args.keep_b64:
            run(sock, f"rm -f {stage}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
