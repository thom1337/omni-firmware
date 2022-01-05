DESCRIPTION = "Skyline tools required for components build"

inherit packagegroup

PACKAGES = " \
    packagegroup-skyline-rdep \
"

RDEPENDS_packagegroup-skyline-rdep = " \
   boost \
   jsoncpp \
   libcrypto \
   libcurl \
   libnl \
   libnl-genl \
   libnl-nf \
   libnl-route \
   libpcap \
   libpcre2 \
   libssl \
   protobuf-lite \
   pugixml \
   util-linux-libuuid \
"

RDEPENDS_packagegroup-skyline-rdep_append_meson-apollo = " \
   libssh2 \
   libtar \
   libtins \
   zlib \
"
