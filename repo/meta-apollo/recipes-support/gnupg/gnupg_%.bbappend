# Force -fcommon to avoid issues with GCC 10 (which defaults to -fno-common)
BUILD_CFLAGS += "-fcommon"
CFLAGS += "-fcommon"
