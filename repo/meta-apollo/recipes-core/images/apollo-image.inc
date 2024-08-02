python __anonymous() {
    rootpw = d.getVar('APOLLO_ROOT_PASSWORD')
    if rootpw:
        d.setVar('EXTRA_USERS_PARAMS', 'usermod -p \'{}\' root;'.format(rootpw))
}

IMAGE_INSTALL_append = " \
    avahi-daemon \
    base-files-fstab-volatile \
    coreutils \
    cpio \
    dhcp-server \
    e2fsprogs-mke2fs \
    findutils \
    gawk \
    grep \
    iproute2 \
    iproute2-tc \
    ipset \
    iptables \
    iputils \
    kernel-modules \
    kmod \
    less \
    logrotate \
    lsof \
    packagegroup-core-boot \
    procps \
    rng-tools \
    sed \
    tcpdump \
    u-boot-fw-utils-apollo \
    openssh-sshd \
    openssh-scp \
    netcat-openbsd \
    vim \
    htop \
"

IMAGE_FSTYPES_remove = "wic"
IMAGE_FSTYPES += "ext4"

inherit core-image extrausers
ROOTFS_POSTPROCESS_COMMAND += "deploy_initramfs; "
deploy_initramfs() {
    IMAGES=${@d.getVar('DEPLOY_DIR_IMAGE')}
    INITRAMFS=${@d.getVar('INITRAMFS_IMAGE_NAME')}
    MACH=${@d.getVar('MACHINE')}

    install -D -m 0644 ${IMAGES}/${INITRAMFS}-${MACH}.cpio.gz ${IMAGE_ROOTFS}/boot
}

IMAGE_ROOTFS_SIZE = "150000"
IMAGE_ROOTFS_MAXSIZE = "850000"
IMAGE_OVERHEAD_FACTOR = "1.05"

# following solution have higher memory consuption
# SDKIMAGE_FEATURES += "staticdev-pkgs dev-pkgs dbg-pkgs"
# or
TOOLCHAIN_TARGET_TASK += " \
    abseil-cpp-staticdev \
    libstdc++-staticdev \
    pegtl-dev \
    pugixml-staticdev \
"

TOOLCHAIN_HOST_TASK += " \
    nativesdk-make \
    nativesdk-protobuf \
    nativesdk-protobuf-c \
    nativesdk-protobuf-c-compiler \
"

IMAGE_INSTALL_append = " \
    avahi-daemon \
    bc \
    conntrack-tools \
    curl \
    dnsmasq \
    jemalloc \
    jq \
    openssl \
    util-linux \
"

IMAGE_INSTALL_append = " \
    perf \
"
# libraries required by skyline components
IMAGE_INSTALL_append = " \
    packagegroup-skyline-rdep \
"

IMAGE_BASENAME_append = "-${DISTRO_VERSION}-${APOLLO_ENVIRONMENT}"

SDK_POSTPROCESS_COMMAND += "remove_locales; "
remove_locales() {
    rm -rf ${WORKDIR}/sdk/image/${SDKPATHNATIVE}/usr/lib/locale
}
