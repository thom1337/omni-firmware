# Builder container for the Avast Omni Debian slot image (rootfs/build-rootfs.sh).
#
# Deliberately NOT the ubuntu:24.04 base the Yocto builder uses: the image being produced is
# Debian trixie, and the ext4 feature pinning has to be exercised against the same e2fsprogs
# 1.47 that ships there (it is 1.47 that defaults metadata_csum_seed and orphan_file on —
# Debian #1072566 — which is the risk the build asserts against).
#
# Build/run through rootfs/build-in-docker.sh, which does the UID/GID mapping and passes the
# security options mmdebstrap's --mode=unshare needs.
FROM debian:trixie-slim

ARG UID=1000
ARG GID=1000

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      # the rootfs builder itself
      mmdebstrap \
      # arch-test lets mmdebstrap (and build-rootfs.sh) verify that arm64 binaries are
      # actually runnable here before it starts, instead of failing inside a maintainer script
      arch-test \
      # qemu-aarch64-static. binfmt_misc is a host-kernel property and is NOT namespaced, so
      # this binary is only useful when the host registration lacks the F (fix-binary) flag —
      # build-rootfs.sh detects that and copies it into the chroot with a setup-hook.
      qemu-user-static \
      # newuidmap/newgidmap: mmdebstrap --mode=unshare needs a multi-id subuid/subgid map,
      # otherwise every file in the chroot ends up owned by one uid
      uidmap \
      # mke2fs -d / dumpe2fs / e2fsck — the pinned-feature packing step and its assertions
      e2fsprogs \
      # unshare, mount, chroot, blockdev
      util-linux mount \
      # tar with --xattrs, and the compressors dpkg and the image need
      tar gzip pigz xz-utils zstd bzip2 \
      # apt needs these to fetch and verify trixie inside the chroot
      ca-certificates debian-archive-keyring gpgv apt-utils \
      # sudo: the packing step needs real root to preserve ownership, device nodes and
      # valid (rootid 0) file capabilities. Container root is enough; no host sudo involved.
      sudo passwd \
      # misc
      perl file coreutils findutils \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Unprivileged build user, mapped to the invoking host user so the artifacts in rootfs/out
# are not root-owned on the host.
RUN set -eux; \
    if ! getent group "${GID}" >/dev/null; then groupadd -g "${GID}" builder; fi; \
    if ! getent passwd "${UID}" >/dev/null; then \
      useradd -u "${UID}" -g "${GID}" -m -d /home/builder -s /bin/bash builder; \
    else \
      usermod -l builder -d /home/builder -m "$(getent passwd "${UID}" | cut -d: -f1)"; \
    fi; \
    id builder

# mmdebstrap --mode=unshare maps the chroot's uids into this range. Without it the mode
# degrades to a single-id map and package installs that chown fail.
RUN printf 'builder:100000:65536\n' > /etc/subuid && \
    printf 'builder:100000:65536\n' > /etc/subgid

# Passwordless sudo INSIDE the container only. build-rootfs.sh uses it for the ext4 packing
# step; the host is never asked for a password and never runs anything as root.
RUN printf 'builder ALL=(ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder && \
    chmod 0440 /etc/sudoers.d/builder

USER builder
WORKDIR /workdir
