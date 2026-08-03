#!/bin/sh
# omni-tailscale-install.sh - install Tailscale onto a RUNNING Omni from a
# pushed upstream tarball.
#
# The build-time path (rootfs/build-rootfs.sh + the 25-tailscale hook) is the
# one that ships. This is the live path: it puts the same verified upstream
# artefact onto a slot that is already running, so the design can be proven on
# real hardware before it is baked into an image that costs ~11 hours to flash.
# The two must stay in agreement -- if you change where the state lives here,
# change it in rootfs/overlay/etc/systemd/system/tailscaled.service.d/ too.
#
# THE STATE LOCATION IS THE WHOLE POINT. tailscaled defaults its state to
# /var/lib/tailscale, which on this box is inside the PER-SLOT overlay upper
# (p5 for slot A, p6 for slot B). Left there, the node identity belongs to one
# slot and the first A/B flip boots a slot that has never authenticated -- the
# device silently drops off the tailnet after every update, headless. It goes
# on /data (p3), the only partition both slots share.
#
# NO AUTH KEY IS INSTALLED. Enrol afterwards with `tailscale up`, or drop one at
# /data/tailscale/authkey and start omni-tailscale-auth.service.
set -eu

TGZ="${1:-/data/ts/tailscale_1.98.10_arm64.tgz}"
# Pinned to match rootfs/build-rootfs.sh. Bump both together.
WANT_SHA="d74a84e07cb1948d9f09a23ae161417c6127e562949773705c95d0762be2809d"

say() { printf 'omni-tailscale-install: %s\n' "$*"; }
die() { printf 'omni-tailscale-install: ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"
[ -s "$TGZ" ] || die "tarball not found: $TGZ"

say "verifying $TGZ"
got=$(sha256sum "$TGZ" | cut -d' ' -f1)
[ "$got" = "$WANT_SHA" ] || die "checksum MISMATCH
  expected $WANT_SHA
  got      $got
This is the same digest the build pins. Refusing to install."
say "checksum ok: $got"

tmp=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$tmp'" EXIT
tar xzf "$TGZ" -C "$tmp"
src=$(find "$tmp" -maxdepth 1 -type d -name 'tailscale_*_arm64' | head -1)
[ -n "$src" ] || die "unexpected tarball layout"

say "installing binaries"
install -D -m 0755 "$src/tailscaled" /usr/sbin/tailscaled
install -D -m 0755 "$src/tailscale"  /usr/bin/tailscale
install -D -m 0644 "$src/systemd/tailscaled.service" /usr/lib/systemd/system/tailscaled.service
[ -f /etc/default/tailscaled ] || install -D -m 0644 "$src/systemd/tailscaled.defaults" /etc/default/tailscaled

# State on /data, never the per-slot overlay. 0700: this file IS the machine's
# identity on the tailnet.
say "pinning state to /data/tailscale"
mkdir -p /data/tailscale
chmod 0700 /data/tailscale
rm -rf /var/lib/tailscale

mkdir -p /etc/systemd/system/tailscaled.service.d
cat > /etc/systemd/system/tailscaled.service.d/10-omni.conf <<'DROPIN'
# See tools/omni-tailscale-install.sh and rootfs/overlay/.../tailscaled.service.d
# Default state is /var/lib/tailscale, which is the PER-SLOT overlay upper here.
# The node identity would belong to one slot and be lost on the first A/B flip.
[Unit]
# /data is nofail in fstab, so it can legitimately be absent; without this
# tailscaled starts anyway and writes its identity somewhere that vanishes.
RequiresMountsFor=/data

[Service]
ExecStart=
ExecStart=/usr/sbin/tailscaled \
    --state=/data/tailscale/tailscaled.state \
    --socket=/run/tailscale/tailscaled.sock \
    --port=${PORT} \
    $FLAGS
# The packaged unit's StateDirectory= would recreate the per-slot path.
StateDirectory=
Restart=on-failure
RestartSec=5s
DROPIN

systemctl daemon-reload
systemctl enable tailscaled.service >/dev/null 2>&1 || true
systemctl restart tailscaled.service

sleep 3
if systemctl is-active --quiet tailscaled; then
    say "tailscaled is running"
else
    die "tailscaled failed to start -- journalctl -u tailscaled"
fi

say "version: $(tailscale version 2>/dev/null | head -1 || echo unknown)"
say "state:   $(tailscale status 2>&1 | head -1 || true)"
cat <<'NEXT'

Next, to join the tailnet (needs a working uplink -- this box has no carrier
until a cable is attached):

    tailscale up --accept-dns=false

or, unattended, drop a pre-auth key and let the oneshot do it:

    printf '%s\n' 'tskey-auth-...' > /data/tailscale/authkey
    chmod 0600 /data/tailscale/authkey
    systemctl start omni-tailscale-auth

The identity lands in /data/tailscale/tailscaled.state, which is shared by both
A/B slots -- so an update or a rollback keeps the same node.
NEXT
