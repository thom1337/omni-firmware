#!/usr/bin/env python3
"""Write a disk image to an Omni partition over the serial console.

Why this exists
---------------
The unit has no network, and the Debian slot image is 850 MiB (188 MiB gzipped).
At the console's ~8.8 KB/s that is an eight-hour write, which changes what the
tool has to be: a single stream that dies at hour seven and leaves a
half-written slot with no way to tell how far it got is not acceptable. So this
is chunked, resumable and verified per chunk.

  * The image is sliced into fixed RAW chunks. Each is gzipped and base64'd
    independently, pushed, and piped on the device straight into
    `dd of=<part> seek=<chunk> conv=notrunc,fsync` -- so nothing is ever staged
    on the device. /data has only ~95 MiB free and could not hold the image
    anyway.
  * After every chunk the device reads that region BACK off the eMMC and hashes
    it. A chunk that does not match is retried; three failures abort. This makes
    a silent corruption impossible rather than unlikely, which matters because
    the failure would otherwise surface as an unbootable slot hours later.
  * Verified chunks are recorded in a local state file, so --resume picks up
    where it stopped and costs one chunk of rework at most.

Safety
------
This WRITES A BLOCK DEVICE. It refuses to run unless:
  * the target is not mounted anywhere on the device,
  * the target is not the partition the device is currently rooted on,
  * the target is at least as large as the image.
Slot B (p2) on the measured unit is a formatted but empty ext4 that has never
been booted, which is what makes it safe to overwrite.

Usage
  OMNI_CONSOLE_HOST=<ip> tools/omni-dd-push.py IMAGE.gz --target /dev/mmcblk0p2
  OMNI_CONSOLE_HOST=<ip> tools/omni-dd-push.py IMAGE.gz --target /dev/mmcblk0p2 --resume
"""
import argparse
import base64
import gzip
import hashlib
import json
import os
import socket
import sys
import time

HOST = os.environ.get("OMNI_CONSOLE_HOST", "127.0.0.1")
PORT = int(os.environ.get("OMNI_CONSOLE_PORT", "4445"))
MIB = 1 << 20


def drain(sock, quiet=0.5, timeout=30.0, first_byte=None):
    """Read until the link goes quiet, or `timeout`.

    `first_byte` is how long to wait for the FIRST byte before giving up. It must
    be separate from `quiet`, and this is not a nicety: a command like
    `sha256sum` over 850 MiB of eMMC on a 512 MB ARM box prints NOTHING for
    minutes and then emits one line. With a single silence threshold the reader
    returns empty long before the answer arrives and the caller concludes the
    digest failed -- turning a perfectly good eight-hour write into a false
    "MISMATCH". Callers that run long device-side commands must pass a
    first_byte generous enough for the work.
    """
    if first_byte is None:
        first_byte = min(timeout, quiet * 4)
    buf = b""
    start = last = time.monotonic()
    sock.settimeout(0.2)
    while True:
        now = time.monotonic()
        if now - start > timeout:
            break
        if buf and (now - last) > quiet:
            break
        if not buf and (now - start) > first_byte:
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


def run(sock, cmd, quiet=0.6, timeout=60.0, first_byte=None):
    sock.sendall(cmd.encode() + b"\n")
    return drain(sock, quiet, timeout, first_byte)


def send_paced(sock, data, rate, block=512):
    """Line-wrapped payload, paced under the line rate. See omni-push.py for the
    two traps this avoids: MAX_CANON truncation and mistaking sendall() for
    delivery."""
    total = len(data)
    sent = 0
    t0 = time.monotonic()
    while sent < total:
        piece = data[sent:sent + block]
        sock.sendall(piece)
        sent += len(piece)
        target = t0 + (sent / float(rate))
        slack = target - time.monotonic()
        if slack > 0:
            time.sleep(slack)
    return sent


def wrap_b64(raw):
    flat = base64.b64encode(raw).decode()
    return ("\n".join(flat[i:i + 76] for i in range(0, len(flat), 76)) + "\n").encode()


def main():
    ap = argparse.ArgumentParser(description="Write an image to an Omni partition over serial.")
    ap.add_argument("image", help="image file (.gz or raw)")
    ap.add_argument("--target", required=True, help="device-side block device, e.g. /dev/mmcblk0p2")
    ap.add_argument("--chunk-mib", type=int, default=8)
    ap.add_argument("--rate", type=float, default=8000.0,
                    help="bytes/sec. Must stay UNDER the measured ~8.8 KB/s line rate")
    ap.add_argument("--resume", action="store_true")
    ap.add_argument("--state", default="")
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument("--host", default=HOST)
    ap.add_argument("--port", type=int, default=PORT)
    args = ap.parse_args()

    opener = gzip.open if args.image.endswith(".gz") else open
    with opener(args.image, "rb") as f:
        image = f.read()
    total = len(image)
    chunk = args.chunk_mib * MIB
    nchunks = (total + chunk - 1) // chunk
    whole = hashlib.sha256(image).hexdigest()

    state_path = args.state or (args.image + ".ddpush-state.json")
    if not args.resume and os.path.exists(state_path):
        sys.stderr.write(
            f"A state file already exists: {state_path}\n"
            "  Pass --resume to continue that transfer, or delete the file to start over.\n"
            "  Refusing to silently discard a record of previously verified chunks.\n")
        return 2
    done = set()
    if args.resume and os.path.exists(state_path):
        st = json.load(open(state_path))
        if (st.get("sha256") == whole and st.get("target") == args.target
                and st.get("chunk_mib") == args.chunk_mib):
            done = set(st.get("done", []))
            print(f"resuming: {len(done)}/{nchunks} chunks already verified", flush=True)
        else:
            print("state file does not match this image/target/chunk size; starting over", flush=True)

    print(f"image {total} bytes ({total/MIB:.0f} MiB), sha256 {whole[:16]}…", flush=True)
    print(f"{nchunks} chunks of {args.chunk_mib} MiB -> {args.target}", flush=True)

    with socket.create_connection((args.host, args.port), timeout=10) as sock:
        sock.settimeout(0.2)
        drain(sock, 0.4, 3.0)

        if "root" not in run(sock, "id -un"):
            sys.stderr.write("not at a root shell on the device\n")
            return 3

        # --- refuse to write something we should not -------------------------
        # Each fact is fetched on its own and fenced by a unique marker. The
        # earlier version parsed three chained commands out of one console read
        # and then guessed which line was which; on this device the read also
        # contains the echoed command and zsh line-editor escapes, so the
        # mounted-check could never fire and the size-check silently skipped
        # itself. Both failed OPEN, which is the wrong direction for something
        # that overwrites a block device.
        def fact(cmd, marker):
            out = run(sock, f"echo {marker}_BEGIN; {cmd}; echo {marker}_END",
                      quiet=1.0, timeout=60.0, first_byte=20.0)
            if f"{marker}_BEGIN" not in out or f"{marker}_END" not in out:
                return None
            body = out.split(f"{marker}_BEGIN", 1)[1].rsplit(f"{marker}_END", 1)[0]
            # Drop the echoed command line and any escape noise.
            return [l.strip() for l in body.splitlines()
                    if l.strip() and marker not in l and "echo" not in l]

        tgt = args.target
        mnt = fact(f"grep -c '^{tgt} ' /proc/mounts || true", "OMNIMNT")
        if mnt is None:
            sys.stderr.write("REFUSING: could not determine whether the target is mounted\n")
            return 4
        if mnt and mnt[-1] != "0":
            sys.stderr.write(f"REFUSING: {tgt} appears mounted on the device ({mnt[-1]})\n")
            return 4

        rootdev = fact("grep -o 'root=[^ ]*' /proc/cmdline", "OMNIROOT")
        if rootdev is None:
            sys.stderr.write("REFUSING: could not read the running root from /proc/cmdline\n")
            return 4
        if any(l.split("=", 1)[-1] == tgt for l in rootdev):
            sys.stderr.write(f"REFUSING: {tgt} is the running root filesystem\n")
            return 4

        # Whole-disk guard. /dev/mmcblk0 is one keystroke from /dev/mmcblk0p2 and
        # would take the partition table, both slots, /data and recovery with it.
        parts = fact(f"ls -1 {tgt}p1 2>/dev/null && echo HASPARTS", "OMNIWHOLE")
        if parts and any("HASPARTS" in l for l in parts):
            sys.stderr.write(f"REFUSING: {tgt} looks like a WHOLE DISK ({tgt}p1 exists), not a partition\n")
            return 4

        szl = fact(f"blockdev --getsize64 {tgt}", "OMNISZ")
        size = next((int(l) for l in (szl or []) if l.isdigit()), None)
        if size is None:
            sys.stderr.write(f"REFUSING: could not read the size of {tgt}\n")
            return 4
        if size < total:
            sys.stderr.write(f"REFUSING: {tgt} is {size} bytes, image is {total}\n")
            return 4
        print(f"target {tgt}: {size} bytes, a partition, not mounted, not the running root", flush=True)

        run(sock, "stty -echo", quiet=0.4, timeout=10)
        t_start = time.monotonic()
        this_run = 0
        try:
            for i in range(nchunks):
                if i in done:
                    continue
                raw = image[i * chunk:(i + 1) * chunk]
                want = hashlib.sha256(raw).hexdigest()
                payload = wrap_b64(gzip.compress(raw, 9))

                for attempt in range(1, args.retries + 1):
                    sock.sendall(
                        f"head -c {len(payload)} | base64 -d | gzip -dc | "
                        f"dd of={args.target} bs=1M seek={i * args.chunk_mib} "
                        f"conv=notrunc,fsync 2>/dev/null\n".encode())
                    time.sleep(1.0)
                    drain(sock, 0.3, 3.0)
                    send_paced(sock, payload, args.rate)
                    drain(sock, 2.0, 240.0)   # wait for dd to finish and the prompt

                    # drop_caches first: conv=fsync pushes the write out to the eMMC,
                    # but without this the read-back is served from the page cache and
                    # verifies our own RAM rather than the media.
                    got = run(sock,
                              f"sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; "
                              f"dd if={args.target} bs=1M skip={i * args.chunk_mib} "
                              f"count={args.chunk_mib} 2>/dev/null | head -c {len(raw)} | "
                              f"sha256sum | cut -d' ' -f1",
                              quiet=2.0, timeout=300.0, first_byte=120.0)
                    if want in got:
                        break
                    print(f"  chunk {i} verify FAILED (attempt {attempt}/{args.retries})", flush=True)
                else:
                    sys.stderr.write(
                        f"\nchunk {i} failed verification {args.retries} times -- aborting.\n"
                        f"  {len(done)}/{nchunks} chunks are written and verified.\n"
                        f"  Re-run with --resume to continue from here.\n")
                    return 5

                done.add(i)
                # Write-then-rename: a crash during the write must not be able to
                # truncate the only record of hours of verified transfer.
                tmp = state_path + ".tmp"
                with open(tmp, "w") as sf:
                    json.dump({"sha256": whole, "target": args.target,
                               "chunk_mib": args.chunk_mib, "done": sorted(done)}, sf)
                    sf.flush()
                    os.fsync(sf.fileno())
                os.replace(tmp, state_path)

                el = time.monotonic() - t_start
                # Rate over chunks done IN THIS RUN. Using len(done) would divide
                # this run's elapsed time by chunks a previous run had already
                # finished, and a resumed run would report a nonsense ETA.
                this_run += 1
                per = el / this_run
                remaining = nchunks - len(done)
                print(f"  chunk {i+1}/{nchunks} verified  "
                      f"({100.0*len(done)/nchunks:.1f}%, elapsed {el/3600:.2f} h, "
                      f"ETA {per*remaining/3600:.2f} h)", flush=True)
        finally:
            run(sock, "stty echo", quiet=0.6, timeout=15)

        print("\nall chunks verified individually; checking the whole partition", flush=True)
        # The device goes SILENT for 30-45 s here: 850 MiB off eMMC plus a
        # coreutils-6.9 generic-C sha256 on a 1.2 GHz A53. drain()'s idle-gap rule
        # cannot survive that, and a first_byte budget does not rescue it either --
        # zsh ECHOES the command back within ~50 ms, so `buf` is immediately
        # non-empty and the `quiet` rule applies, handing back the echoed command
        # while the device is still working. That would report a false MISMATCH
        # after eight hours of correct work, on the ONLY media-level check in the
        # tool. So wait passively for an explicit end marker instead.
        #
        # The marker is SPLIT in the source on purpose: the echoed command line
        # contains EN''D_<nonce>, and only the device's real output reassembles
        # END_<nonce>. Without the split, the first match is the shell echoing us.
        nonce = "%08x" % (int(time.time()) & 0xffffffff)
        end = ("END_" + nonce).encode()
        sock.sendall((f"sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; "
                      f"head -c {total} {args.target} | sha256sum | cut -d' ' -f1; "
                      f"echo 'EN''D_{nonce}'\n").encode())
        seen = b""
        w0 = last_report = time.monotonic()
        sock.settimeout(1.0)
        while time.monotonic() - w0 < 1800.0:
            try:
                c = sock.recv(4096)
                if not c:
                    break
                seen += c
            except socket.timeout:
                pass
            except OSError:
                break
            if end in seen:
                break
            now = time.monotonic()
            if now - last_report > 30.0:
                print(f"    …device still hashing, {(now-w0)/60:.1f} min elapsed (cap 30 min)",
                      flush=True)
                last_report = now
        if end not in seen:
            sys.stderr.write("\nwhole-image check did not finish within 30 min; verdict UNKNOWN.\n"
                             "  All chunks were individually verified, so the data is probably fine.\n"
                             "  Re-run with --resume to retry just this check.\n")
            return 6
        got = seen.decode("utf-8", "replace").split("END_" + nonce)[0]
        if whole in got:
            print(f"WHOLE-IMAGE SHA256 MATCHES on the device: {whole}", flush=True)
            return 0
        sys.stderr.write(f"\nWHOLE-IMAGE MISMATCH\n  expected {whole}\n  got: {got.strip()[:200]}\n")
        return 6


if __name__ == "__main__":
    sys.exit(main())
