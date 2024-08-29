RDEPENDS:${PN}:remove = "bash"

DEPENDS:remove = "${MLPREFIX}binutils"

do_install:append:class-target() {
    sed "s|#!/bin/bash|#!/bin/sh|g" -i ${D}/usr/libexec/perf-core/perf-with-kcore
    sed "s|#!/bin/bash|#!/bin/sh|g" -i ${D}/usr/libexec/perf-core/perf-archive
}
