RDEPENDS_${PN}_remove = "bash"

DEPENDS_remove = "${MLPREFIX}binutils"

do_install_append_class-target() {
    sed "s|#!/bin/bash|#!/bin/sh|g" -i ${D}/usr/libexec/perf-core/perf-with-kcore
    sed "s|#!/bin/bash|#!/bin/sh|g" -i ${D}/usr/libexec/perf-core/perf-archive
}
