PR = "r1"

EXTRA_OECONF += " \
    --with-ca-path=${sysconfdir}/ssl/certs \
"

# - enable ipv6 support when feature is available
# - use openssl instead of gnutls, it has smaller memory footprint
# - include support for zip encoding
# - asynchronous DNS resolving
# - enable verbose error messages
PACKAGECONFIG += "${@bb.utils.filter('DISTRO_FEATURES', 'ipv6', d)} ssl zlib ares verbose"

PACKAGECONFIG[ssl] = "--without-gnutls --with-ssl --with-random=/dev/urandom,--without-ssl,openssl"
