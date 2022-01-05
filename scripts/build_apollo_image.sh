#!/bin/bash

args=${@:-apollo-image}
shift $#

# wrap default sdk arguments
if [[ "${args}" = "sdk" ]]; then
	args="apollo-image -c populate_sdk"
fi

# Source bitbake and other tools
source /workdir/repo/poky/oe-init-build-env

# Copy configuration files for Apollo

LOCAL=/workdir/build/conf/local.conf
# do not modify existing configuration
if [[ $(grep APOLLO ${LOCAL} | wc -l) -eq 0 ]]; then
	cp /workdir/repo/meta-smarthome-common/conf/local.conf.example ${LOCAL}
	if [ ! -z "$APOLLO_ENVIRONMENT" ] ; then
		sed -i "s|^APOLLO_ENVIRONMENT.*|APOLLO_ENVIRONMENT = \"$APOLLO_ENVIRONMENT\"|" ${LOCAL}
	fi
fi

BBLAYERS=/workdir/build/conf/bblayers.conf
# do not modify existing configuration
if [[ $(grep apollo ${BBLAYERS} | wc -l) -eq 0 ]]; then
	cp /workdir/repo/meta-smarthome-common/conf/bblayers.conf.example ${BBLAYERS}
	# Define root
	sed -i 's\^LAYERS.*\LAYERS = "/workdir/repo"\' ${BBLAYERS}
	# TODO: set direcotries propperly, for now shared directories are removed
	sed -i '/^SSTATE_MIRRORS.*/d' ${BBLAYERS}

	if [ -z "$SSTATE_DIR" ] ; then
		sed -i '/^SSTATE_DIR.*/d' ${BBLAYERS}
	else
		sed -i "s|^SSTATE_DIR.*|SSTATE_DIR = \"$SSTATE_DIR\"|" ${BBLAYERS}
	fi

	if [ -z "$DL_DIR" ] ; then
		sed -i 's|^DL_DIR.*|# DL_DIR ?= "/downloads"|' ${BBLAYERS}
	else
		sed -i "s|^DL_DIR.*|DL_DIR = \"$DL_DIR\"|" ${BBLAYERS}
	fi
fi

# Build target image passed as arg or default
bitbake ${args}
