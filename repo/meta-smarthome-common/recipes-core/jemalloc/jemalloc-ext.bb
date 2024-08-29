require jemalloc.inc

DESCRIPTION += " with debug features enabled"
EXTRA_OECONF += "--enable-fill --enable-debug"

RPROVIDES:${PN} = "jemalloc"
RCONFLICTS:${PN} = "jemalloc"
RREPLACES:${PN} = "jemalloc"
