FILES_${PN}-dev += "/usr/share/pegtl/cmake/"

# Header-only library
RDEPENDS_${PN}-dev = ""
RRECOMMENDS_${PN}-dbg = "${PN}-dev (= ${EXTENDPKGV})"

# gcc 10 warning
CXXFLAGS += " -Wno-error=type-limits"
