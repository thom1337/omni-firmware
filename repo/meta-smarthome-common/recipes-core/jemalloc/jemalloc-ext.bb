require jemalloc.inc

DESCRIPTION += " with debug features enabled"
EXTRA_OECONF += "--enable-fill --enable-debug"

RPROVIDES_${PN} = "jemalloc"
RCONFLICTS_${PN} = "jemalloc"
RREPLACES_${PN} = "jemalloc"
