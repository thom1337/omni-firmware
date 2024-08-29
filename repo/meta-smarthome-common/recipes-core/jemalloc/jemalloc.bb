require jemalloc.inc

EXTRA_OECONF += "--disable-fill"
RCONFLICTS:${PN} = "jemalloc-debug"
