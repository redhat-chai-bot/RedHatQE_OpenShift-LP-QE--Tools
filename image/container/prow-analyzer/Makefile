.PHONY: build push clean help

SHELL := /bin/bash

IMAGE_REGISTRY  ?= images.paas.redhat.com
IMAGE_NAMESPACE ?= ieng/app
IMAGE_REPO      ?= prow-analyzer
IMAGE_TAG       ?= latest
IMAGE_NAME       = $(IMAGE_REGISTRY)/$(IMAGE_NAMESPACE)/$(IMAGE_REPO):$(IMAGE_TAG)
IMAGE_LATEST     = $(IMAGE_REGISTRY)/$(IMAGE_NAMESPACE)/$(IMAGE_REPO):latest

# Application source directory (relative to repo root)
APP_DIR = apps/prow-analyzer

# Build the application image with both requested and latest tags.
build:
	{ set -euxo pipefail; shopt -s inherit_errexit;\
	    : 'Building container image: $(IMAGE_NAME) (also tagged $(IMAGE_LATEST))';\
	    podman build $(BUILDFLAGS) -t '$(IMAGE_NAME)' -t '$(IMAGE_LATEST)' -f Dockerfile '../../../$(APP_DIR)';\
	}

# Push container image to registry. Push both the requested tag and :latest so a
# tagged build (e.g. IMAGE_TAG=v1.0.0) also advances :latest registry-side.
push: build
	{ set -euxo pipefail; shopt -s inherit_errexit;\
	    : 'Pushing container images: $(IMAGE_NAME) and $(IMAGE_LATEST)';\
	    podman push '$(IMAGE_NAME)';\
	    podman push '$(IMAGE_LATEST)';\
	}

# Clean local images
clean:
	{ set -euxo pipefail; shopt -s inherit_errexit;\
	    : 'Removing local images: $(IMAGE_NAME) and $(IMAGE_LATEST)';\
	    podman rmi '$(IMAGE_NAME)' '$(IMAGE_LATEST)' || true;\
	}

# Help
help:
	@printf '%s\n' \
		'Prow Analyzer Container Build' \
		'' \
		'Available targets:' \
		'  build  - Build container image (default: $(IMAGE_NAME), also tagged $(IMAGE_LATEST))' \
		'  push   - Build and push container image to registry' \
		'  clean  - Remove local container image' \
		'' \
		'Variables:' \
		'  IMAGE_REGISTRY  - Container registry (default: $(IMAGE_REGISTRY))' \
		'  IMAGE_NAMESPACE - Registry namespace (default: $(IMAGE_NAMESPACE))' \
		'  IMAGE_REPO      - Image repository name (default: $(IMAGE_REPO))' \
		'  IMAGE_TAG       - Image tag (default: $(IMAGE_TAG))' \
		'  IMAGE_NAME      - Full image reference composed from the vars above (default: $(IMAGE_NAME))' \
		'' \
		'Example:' \
		'  make build IMAGE_TAG=v1.0.0' \
		'  make push IMAGE_REGISTRY=quay.io IMAGE_NAMESPACE=myorg IMAGE_TAG=v1.0.0'
