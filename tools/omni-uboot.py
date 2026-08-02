#!/usr/bin/env python3
"""Reach the Omni's U-Boot "=>" prompt over serial and run READ-ONLY commands.

Why this exists
---------------
Two things in docs/ARMBIAN-MIGRATION.md can only be done at the U-Boot prompt:

  * P5, the plan's risk #1. check_watchdog is
        itest.w *0xff80023c -eq 0xd000
    and it runs AHEAD of A/B slot selection, while altbootcmd ends in
    `run bootcmd` which re-evaluates it. So if some reset type latches that
    halfword to 0xd000, every boot is trapped in the p7 recovery slot and
    bootcount rollback provably cannot escape. The register cannot be read from
    Linux -- STRICT_DEVMEM blocks /dev/mem -- so it has to be read here.
  * Phase 4's GO/NO-GO trial boot, which loads the new kernel entirely from the
    prompt so that a power cycle undoes 100% of it.

The measured unit has bootdelay=2. Two seconds is too tight to hand-time over a
TCP-bridged serial link, so this spams an interrupt key across the window.

Safety
------
This tool REFUSES to send anything that writes. In particular `saveenv`: the
Mender boot code does `setenv bootargs root=${mender_kernel_root} ${bootargs}`
on every boot, so a saveenv taken after that has run persists a bootargs with a
root= baked in, and every later boot appends another one -- into a single
non-redundant 8 KB environment block that holds the only copy of ethaddr.
`--allow-writes` exists for the operator who has read that paragraph and means
it; it is never the default.

Usage
-----
  OMNI_CONSOLE_HOST=<ip> tools/omni-uboot.py p5
      reboot, catch the prompt, read 0xff80023c, resume the boot

  OMNI_CONSOLE_HOST=<ip> tools/omni-uboot.py run "md.w 0xff80023c 1" "bdinfo"
      catch the prompt (triggering a reboot unless --no-reboot) and run commands

  OMNI_CONSOLE_HOST=<ip> tools/omni-uboot.py run "printenv bootdelay" --no-reboot

ARGUMENT ORDER: the commands are a positional list, so they must come BEFORE the
flags -- `run "md.w 0xff80023c 1" --no-login`, NOT `run --no-login "md.w ..."`.
argparse otherwise folds the command into the preceding option and exits 2.

STATE: `run`/`p5` resume the boot with `boot` unless --no-resume is given, so a
follow-up invocation with --no-reboot will NOT find a prompt -- the box is back
in Linux by then. Chain with --no-resume when you want to stay at "=>".
      assume the box is ALREADY sitting at the prompt

Options
  --trigger CMD   how to reset (default "reboot"; use "" if already rebooting)
  --no-reboot     do not trigger a reset; expect the prompt already
  --no-resume     leave the box sitting at the prompt instead of `boot`
  --allow-writes  permit commands this tool otherwise refuses
  --timeout N     seconds to wait for the prompt (default 120)
"""
import argparse
import os
import re
import socket
import sys
import time

HOST = os.environ.get("OMNI_CONSOLE_HOST", "127.0.0.1")
PORT = int(os.environ.get("OMNI_CONSOLE_PORT", "4445"))
PROMPT = b"=>"
# CSI / OSC / charset-select escapes emitted by zsh's line editor on the device.
ANSI = re.compile(rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[()][A-Za-z0-9]|\x1b[@-Z\\-_]")

# Anything that can persist state, rewrite storage, or brick the unit.
# saveenv is the headline, but mmc/nand/sf writes and env default are equally final.
FORBIDDEN = re.compile(
    r"\b(saveenv|env\s+save|env\s+default|setenv|editenv|mmc\s+write|mmc\s+erase|"
    r"mmc\s+bootbus|mmc\s+partconf|mmc\s+hwpartition|nand\s+(write|erase|scrub)|"
    r"sf\s+(write|erase|update)|erase|cp\.[bwl]|mw\.[bwl]|mw|nvedit|fatwrite|"
    r"ext4write|gpt\s+write|mbr\s+write|bootefi|dfu|ums)\b",
    re.IGNORECASE,
)


def emit(chunk):
    sys.stdout.write(chunk.decode("utf-8", "replace"))
    sys.stdout.flush()


def rd(sock, buf):
    try:
        c = sock.recv(4096)
        if c:
            buf += c
            emit(c)
    except socket.timeout:
        pass
    return buf


def ensure_logged_in(sock, user, password, timeout=75.0):
    """Get to a Linux shell before the reset trigger is sent.

    Without this the trigger is typed at `avast-omni login:` as a USERNAME, the
    getty then asks for a password, and login times out 60 s later having done
    nothing at all -- the box never reboots and the "=>" window never opens.
    That failure is silent unless you read the transcript, so it is handled here
    rather than left to the caller.
    """
    buf = b""
    sock.sendall(b"\n")
    t0 = time.monotonic()
    state = "probe"
    while time.monotonic() - t0 < timeout:
        buf = rd(sock, buf)
        tail = buf[-300:]
        if state == "probe" and b"login:" in tail:
            print("\n--- login prompt: authenticating ---", flush=True)
            sock.sendall(user.encode() + b"\n")
            state = "sent-user"
            time.sleep(1.5)
            continue
        if state == "sent-user" and b"assword" in tail:
            sock.sendall(password.encode() + b"\n")
            state = "sent-pass"
            time.sleep(2.5)
            continue
        # A shell prompt ends in '#' (root) or '$' -- but ONLY after the terminal
        # escapes are removed. The stock image runs zsh with its line editor on,
        # so the prompt actually arrives as e.g.
        #     ESC[Javast-omni# ESC[K ESC[?2004h
        # and a naive last-byte check sees 'h' from the bracketed-paste enable.
        clean = ANSI.sub(b"", tail).rstrip()
        if clean[-1:] in (b"#", b"$") and b"login:" not in clean[-40:]:
            return True
        if state == "probe":
            sock.sendall(b"\n")
        time.sleep(0.5)
    return False


def catch_prompt(sock, trigger, timeout):
    buf = b""
    for _ in range(10):
        buf = rd(sock, buf)
    if trigger:
        print(f"\n--- trigger: {trigger!r} ---", flush=True)
        sock.sendall(trigger.encode() + b"\n")
    print("--- spamming interrupt key, waiting for => ---", flush=True)
    start = time.monotonic()
    while time.monotonic() - start < timeout:
        sock.sendall(b" ")
        buf = rd(sock, buf)
        if PROMPT in buf[-4000:]:
            print("\n--- AT U-BOOT PROMPT ---", flush=True)
            time.sleep(1.0)
            for _ in range(6):
                buf = rd(sock, buf)
            sock.sendall(b"\n")          # clear the accumulated spaces
            time.sleep(0.6)
            for _ in range(6):
                buf = rd(sock, buf)
            return True, buf
        time.sleep(0.12)
    return False, buf


def run_cmd(sock, cmd, settle=6.0):
    mark_note = f"\n--- => {cmd} ---"
    print(mark_note, flush=True)
    buf = b""
    sock.sendall(cmd.encode() + b"\n")
    t0 = time.monotonic()
    while time.monotonic() - t0 < settle:
        buf = rd(sock, buf)
    return buf.decode("utf-8", "replace")


def main():
    ap = argparse.ArgumentParser(description="Drive the Omni U-Boot prompt, read-only by default.")
    ap.add_argument("mode", choices=["p5", "run"])
    ap.add_argument("commands", nargs="*", default=[])
    ap.add_argument("--trigger", default="reboot")
    ap.add_argument("--no-reboot", action="store_true")
    ap.add_argument("--no-resume", action="store_true")
    ap.add_argument("--allow-writes", action="store_true")
    ap.add_argument("--login-user", default="root")
    ap.add_argument("--login-pass", default="", help="or set OMNI_LOGIN_PASS; never hardcode it here")
    ap.add_argument("--no-login", action="store_true", help="console is already at a shell")
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--host", default=HOST)
    ap.add_argument("--port", type=int, default=PORT)
    args = ap.parse_args()

    cmds = ["md.w 0xff80023c 1"] if args.mode == "p5" else list(args.commands)
    if not cmds:
        sys.stderr.write("no commands given\n")
        return 2

    if not args.allow_writes:
        for c in cmds:
            if FORBIDDEN.search(c):
                sys.stderr.write(
                    f"REFUSING {c!r}: it can write persistent state.\n"
                    "  The environment is a single non-redundant 8 KB block holding the only\n"
                    "  copy of ethaddr, and MENDER_BOOTARGS rewrites bootargs on every boot,\n"
                    "  so a saveenv here permanently accumulates duplicate root= entries.\n"
                    "  Pass --allow-writes only if you have read that and mean it.\n")
                return 3

    trigger = "" if args.no_reboot else args.trigger
    with socket.create_connection((args.host, args.port), timeout=10) as sock:
        sock.settimeout(0.2)
        if trigger and not args.no_login:
            password = args.login_pass or os.environ.get("OMNI_LOGIN_PASS", "")
            if not password:
                sys.stderr.write(
                    "no login password: pass --login-pass or set OMNI_LOGIN_PASS.\n"
                    "  The reset trigger has to be typed at a SHELL. Typed at the\n"
                    "  login prompt it becomes a username and the box never reboots.\n"
                    "  Use --no-login only if the console is already at a shell.\n")
                return 4
            if not ensure_logged_in(sock, args.login_user, password):
                print("\n--- could not reach a shell prompt ---", flush=True)
                return 5
        ok, _ = catch_prompt(sock, trigger, args.timeout)
        if not ok:
            print(f"\n--- NO PROMPT within {args.timeout:.0f}s ---", flush=True)
            print("bootdelay must be >= 0 for abortboot() to prompt; check "
                  "`fw_printenv bootdelay` (it was 2 on the measured unit).", flush=True)
            return 1

        outputs = {c: run_cmd(sock, c) for c in cmds}

        print("\n" + "=" * 64, flush=True)
        if args.mode == "p5":
            tail = outputs[cmds[0]]
            m = re.search(r"ff80023c:\s*([0-9a-fA-F]+)", tail)
            if m:
                val = int(m.group(1), 16)
                print(f"RECOVERY REGISTER 0xff80023c = 0x{val:04x}")
                if val == 0xD000:
                    print("*** MATCHES 0xd000: this boot WOULD divert to recovery p7,")
                    print("*** ahead of A/B selection. Do NOT arm anything until this is")
                    print("*** understood -- altbootcmd re-enters bootcmd and cannot escape it.")
                else:
                    print("does not match 0xd000 -> normal A/B boot, recovery not triggered")
            else:
                print("could not parse the register; see the transcript above")
        print("=" * 64, flush=True)

        if not args.no_resume:
            print("\n--- resuming boot ---", flush=True)
            sock.sendall(b"boot\n")
            t0 = time.monotonic()
            buf = b""
            while time.monotonic() - t0 < 25:
                buf = rd(sock, buf)
        else:
            print("\n--- left at the => prompt (--no-resume) ---", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
