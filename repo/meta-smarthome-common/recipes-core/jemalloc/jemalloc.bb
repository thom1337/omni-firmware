require jemalloc.inc

EXTRA_OECONF += "--disable-fill"
RCONFLICTS_${PN} = "jemalloc-debug"
