DESCRIPTION = "high-level, multiplatform C++ network packet sniffing and crafting library"

LICENSE = "BSD-2-Clause"
LIC_FILES_CHKSUM = "file://LICENSE;md5=dcaaaf1a01e7f9ceb200d383a0d4320c"

DEPENDS = "boost libpcap openssl"

# both patches are merged in master
SRC_URI = "git://git@github.com/mfontanini/libtins.git;protocol=ssh \
    file://0001-Fix-check-whether-we-are-crosscompiling.patch \
    file://0002-cmake-change-install-location-of-cmake-files.patch"

SRCREV = "559b1fb89acaabb49251c4596b724b7d72c48b49"
PV = "4.1"
S = "${WORKDIR}/git"

EXTRA_OECMAKE += "-DLIBTINS_ENABLE_CXX11=1"

inherit cmake
