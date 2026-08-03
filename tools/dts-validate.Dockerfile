# Minimal toolchain for preprocessing and compiling the Omni device tree
# against real mainline kernel headers. Deliberately tiny: this image exists
# only to run cpp + dtc, so a DTS mistake is caught in seconds instead of
# waiting on a full Armbian kernel build.
FROM debian:trixie-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      device-tree-compiler \
      cpp \
      gcc \
      make \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work
