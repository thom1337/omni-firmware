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


def stream_push(sock, b64, stage, block=512, rate=9000.0, echo_off=True):
    """Stream base64 straight into `head -c N > stage` on the device.

    The chunked path does one shell round-trip per chunk, which is fine for a
    30 KB script and hopeless for a 36 MB kernel (tens of thousands of prompts).
    This instead:

      * turns the device tty's ECHO OFF first. The console is half-duplex at
        115200; with echo on, every byte sent is echoed back and the return
        traffic halves the effective throughput.
      * uses `head -c N`, which self-terminates after exactly N bytes, so no
        Ctrl-D/EOF signalling is needed and a short write is detectable.
      * PACES the sender below the line rate. This is not optional and it is
        not paranoia: the device advertises ixon/ixoff, but the TCP-to-serial
        bridge does not propagate XOFF back to us. Sending 13,396 bytes as fast
        as the socket accepted them delivered exactly 4096 -- one tty input
        buffer -- and silently dropped the rest, leaving `head -c` blocked
        forever waiting for bytes that were never coming. sendall() returning
        means "buffered", never "delivered". At 115200 8N1 the link carries
        ~11.5 KB/s, so we deliberately run under that.

      * sends the base64 WRAPPED INTO SHORT LINES. This is the one that actually
        bites. The device tty is in canonical (line) mode, where the input queue
        holds one line and caps at MAX_CANON -- 4096 bytes on Linux. An
        unwrapped base64 blob is a single enormous "line", so everything past
        the first 4096 bytes is discarded by the line discipline before any
        process sees it. Both failed attempts delivered exactly 4096 bytes,
        pacing or not, which is the fingerprint. Wrapping at 76 columns means
        the line discipline completes a line every 77 bytes and never overflows.
        `base64 -d` ignores the newlines.

    base64's alphabet never contains XON (0x11) or XOFF (0x13), so whatever the
    bridge does with flow control it cannot corrupt the payload.
    """
    if echo_off:
        run(sock, "stty -echo", quiet=0.4, timeout=10)
    sock.sendall(f"head -c {len(b64)} > {stage}\n".encode())
    time.sleep(1.0)
    drain(sock, 0.3, 2.0)

    data = b64.encode()
    total = len(data)
    sent = 0
    t0 = time.monotonic()
    last_report = 0.0
    while sent < total:
        piece = data[sent:sent + block]
        sock.sendall(piece)
        sent += len(piece)
        # Deadline pacing: hold the average at `rate` B/s regardless of how fast
        # the socket accepts. Drift-free because the target is computed from the
        # absolute start time, not by accumulating per-block sleeps.
        target = t0 + (sent / float(rate))
        slack = target - time.monotonic()
        if slack > 0:
            time.sleep(slack)
        now = time.monotonic()
        if now - last_report > 30.0:
            el = now - t0
            actual = sent / el if el > 0 else 0
            eta = (total - sent) / actual if actual > 0 else 0
            print(f"  {sent}/{total} ({100.0*sent/total:.1f}%), "
                  f"{actual/1024:.1f} KB/s, ETA {eta/60:.1f} min", flush=True)
            last_report = now
    el = max(time.monotonic() - t0, 0.001)
    print(f"  {sent} bytes sent in {el/60:.1f} min ({sent/el/1024:.1f} KB/s)", flush=True)

    # sendall() only means "buffered by the kernel/bridge", NOT "delivered".
    # The link runs at 115200 (~11 KB/s), so a 17 MB payload is still draining
    # for ~26 minutes after the last send() returns. Checking the digest here
    # reads an incomplete file and reports a bogus corruption.
    #
    # `head -c N` exits after exactly N bytes and the shell then prints its
    # prompt, so the prompt IS the delivery receipt. Wait for it passively --
    # sending anything now would be consumed as payload and corrupt the file.
    budget = max(120.0, 180.0)
    print(f"  waiting for head -c to finish (up to {budget/60:.0f} min)", flush=True)
    seen = b""
    w0 = time.monotonic()
    last = 0.0
    sock.settimeout(1.0)
    while time.monotonic() - w0 < budget:
        try:
            c = sock.recv(4096)
            if c:
                seen += c
        except socket.timeout:
            pass
        except OSError:
            break
        if b"#" in seen[-200:] or b"$" in seen[-200:]:
            break
        now = time.monotonic()
        if now - last > 30.0:
            el2 = now - w0
            print(f"    …{el2/60:.1f} min elapsed of ~{budget/60:.0f} max", flush=True)
            last = now
    print(f"  device finished after {(time.monotonic()-w0)/60:.1f} min", flush=True)

    if echo_off:
        run(sock, "stty echo", quiet=0.6, timeout=15)
    return sent == total


def main():
    ap = argparse.ArgumentParser(description="Push files to the Omni over serial.")
    ap.add_argument("files", nargs="+")
    ap.add_argument("--dest", default="/data/omni-tools")
    ap.add_argument("--chunk", type=int, default=512)
    ap.add_argument("--keep-b64", action="store_true")
    ap.add_argument("--stream", action="store_true",
                    help="stream in one shot instead of one shell round-trip per chunk; "
                         "required for anything above ~1 MB")
    ap.add_argument("--block", type=int, default=512, help="stream write size")
    ap.add_argument("--rate", type=float, default=9000.0,
                    help="bytes/sec to pace at. MUST stay under the ~11.5 KB/s the "
                         "115200 link drains at, or the tty buffer silently drops data")
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
    _flat = base64.b64encode(payload).decode()
    # 76 columns is the classic MIME width; anything well under MAX_CANON (4096)
    # works. The trailing newline matters: head -c counts it.
    b64 = "\n".join(_flat[i:i + 76] for i in range(0, len(_flat), 76)) + "\n"

    print(f"payload: {len(args.files)} file(s), {len(payload)} bytes gz, "
          f"{len(b64)} b64 bytes wrapped at 76 cols, sha256 {digest[:16]}…", flush=True)

    stage = f"{args.dest}.tgz.b64"
    with socket.create_connection((args.host, args.port), timeout=10) as sock:
        sock.settimeout(0.2)
        drain(sock, 0.4, 3.0)

        out = run(sock, "id -un")
        if "root" not in out:
            sys.stderr.write("not at a root shell on the device; log in first\n")
            return 3

        run(sock, f"mkdir -p {args.dest} && rm -f {stage} && echo STAGE_READY")

        if args.stream:
            if not stream_push(sock, b64, stage, block=args.block, rate=args.rate):
                sys.stderr.write("stream did not send the full payload\n")
                return 5
        else:
            total = (len(b64) + args.chunk - 1) // args.chunk
            for i in range(total):
                piece = b64[i * args.chunk:(i + 1) * args.chunk]
                # base64 alphabet is [A-Za-z0-9+/=], so single-quoting is safe.
                run(sock, f"printf '%s' '{piece}' >> {stage}", quiet=0.25, timeout=15)
                if (i + 1) % 10 == 0 or i + 1 == total:
                    print(f"  chunk {i+1}/{total}", flush=True)

        # Verify ON THE DEVICE before anything is extracted or executed.
        out = run(sock, f"base64 -d {stage} | sha256sum | cut -d' ' -f1", quiet=2.0, timeout=600)
        if digest not in out:
            sys.stderr.write(
                "\nDIGEST MISMATCH -- the transfer is corrupt.\n"
                f"  expected {digest}\n  device said: {out.strip()[:200]}\n"
                "  Nothing was extracted. Retry with a smaller --chunk.\n")
            return 4
        print(f"digest verified on device: {digest[:16]}…", flush=True)

        out = run(sock, f"base64 -d {stage} | tar xzf - -C {args.dest} && "
                        f"chmod +x {args.dest}/* 2>/dev/null; ls -1 {args.dest}",
                  quiet=2.0, timeout=600)
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
