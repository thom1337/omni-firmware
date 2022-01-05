TARGET ?= apollo-image

.PHONY: docker-build build

all: .prepare docker-build build

.prepare:
	cd repo/meta-openembedded; git am ../../patches/meta-openembedded/*
	cd repo/poky; git am ../../patches/poky/*
	touch .prepare

docker-build:
	docker build -f Dockerfile --build-arg UID=$(shell id -u) --build-arg GID=$(shell id -g) -t omni-ubuntu .

build:
	docker run \
		--env UID=$(shell id -u) \
		--env GID=$(shell id -g) \
		--rm=true \
		-v $(shell pwd):/workdir \
		-it omni-ubuntu \
		/workdir/scripts/build_apollo_image.sh $(TARGET)