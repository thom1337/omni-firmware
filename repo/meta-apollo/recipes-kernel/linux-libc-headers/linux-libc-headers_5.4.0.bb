require recipes-kernel/linux-libc-headers/linux-libc-headers.inc

LICENSE="CLOSED"
S = "${WORKDIR}/git"

DEPENDS += "rsync-native"

SRCREV = "219d54332a09e8d8741c1e1982f5eae56099de85"
SRC_URI = "git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git;protocol=git;branch=linux-5.4.y"
