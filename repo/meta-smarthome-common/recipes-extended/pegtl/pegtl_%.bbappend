FILES:${PN}-dev += "/usr/share/pegtl/cmake/"

# Header-only library
RDEPENDS:${PN}-dev = ""
RRECOMMENDS:${PN}-dbg = "${PN}-dev (= ${EXTENDPKGV})"

# gcc 10 warning
CXXFLAGS += " -Wno-error=type-limits"
