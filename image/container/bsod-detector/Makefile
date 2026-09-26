.PHONY: build push clean help validate validate-layout
.DEFAULT_GOAL := help
.NOTPARALLEL:

IMAGE_REGISTRY ?= quay.io
IMAGE_NAMESPACE ?= redhatqe
IMAGE_NAME ?= bsod-detector
IMAGE_TAG ?= latest
IMAGE_FULL = $(IMAGE_REGISTRY)/$(IMAGE_NAMESPACE)/$(IMAGE_NAME):$(IMAGE_TAG)

REPO_ROOT = ../../..

# Validate required variables before using them
validate:
	@{ \
	    set -euo pipefail; shopt -s inherit_errexit; \
	    [ -n '$(IMAGE_REGISTRY)' ] || { echo 'ERROR: IMAGE_REGISTRY is empty' >&2; exit 1; }; \
	    [ -n '$(IMAGE_NAMESPACE)' ] || { echo 'ERROR: IMAGE_NAMESPACE is empty' >&2; exit 1; }; \
	    [ -n '$(IMAGE_NAME)' ] || { echo 'ERROR: IMAGE_NAME is empty' >&2; exit 1; }; \
	    [ -n '$(IMAGE_TAG)' ] || { echo 'ERROR: IMAGE_TAG is empty' >&2; exit 1; }; \
	    echo 'Validation passed. IMAGE_FULL=$(IMAGE_FULL)'; \
	}

validate-layout:
	@{ \
	    set -euo pipefail; shopt -s inherit_errexit; \
	    root="$$(cd '$(REPO_ROOT)' && pwd)"; \
	    for path in \
	      apps/bsod-detector/src/scripts/host/watch-crash.sh \
	      apps/bsod-detector/src/scripts/host/recover-natural-crash.sh \
	      apps/bsod-detector/src/scripts/host/rhov-common.sh \
	      apps/bsod-detector/host-tools/extract-dump.sh \
	      image/container/bsod-detector/entrypoint.sh; do \
	      [ -s "$${root}/$${path}" ] || { echo "ERROR: missing build input $${path}" >&2; exit 1; }; \
	    done; \
	    grep -q 'virtctl vnc screenshot' "$${root}/apps/bsod-detector/src/scripts/host/watch-crash.sh"; \
	    grep -q 'virtctl memory-dump get' "$${root}/apps/bsod-detector/src/scripts/host/watch-crash.sh"; \
	    echo 'Container build layout validation passed.'; \
	}

# Build container image
build: validate validate-layout
	@{ \
	    set -euo pipefail; shopt -s inherit_errexit; \
	    echo 'Building container image: $(IMAGE_FULL)'; \
	    [ -d '$(REPO_ROOT)/apps/bsod-detector' ] || { echo 'ERROR: repository-root build context not found' >&2; exit 1; }; \
	    [ -f Dockerfile ] || { echo 'ERROR: Dockerfile not found in current directory' >&2; exit 1; }; \
	    podman build -t '$(IMAGE_FULL)' \
	        -f Dockerfile \
	        '$(REPO_ROOT)'; \
	    echo 'Successfully built: $(IMAGE_FULL)'; \
	}

# Build and push to registry
push: validate build
	@{ \
	    set -euo pipefail; shopt -s inherit_errexit; \
	    echo 'Pushing container image to $(IMAGE_REGISTRY): $(IMAGE_FULL)'; \
	    podman push '$(IMAGE_FULL)'; \
	    echo 'Successfully pushed: $(IMAGE_FULL)'; \
	}

# Remove local image
clean:
	@{ \
	    set -euo pipefail; shopt -s inherit_errexit; \
	    echo 'Removing local image: $(IMAGE_FULL)'; \
	    podman rmi '$(IMAGE_FULL)' || true; \
	}

# Display help
help:
	@{ \
	    echo 'BSOD Detector Container Build'; \
	    echo ''; \
	    echo 'Available targets:'; \
	    echo '  build    - Build container image (default: $(IMAGE_FULL))'; \
	    echo '  push     - Build and push container image to registry'; \
	    echo '  clean    - Remove local container image'; \
	    echo '  validate - Validate required variables'; \
	    echo '  validate-layout - Verify repository-root COPY inputs and required RHOV commands'; \
	    echo ''; \
	    echo 'Variables:'; \
	    echo '  IMAGE_REGISTRY  - Container registry (default: $(IMAGE_REGISTRY))'; \
	    echo '  IMAGE_NAMESPACE - Registry namespace (default: $(IMAGE_NAMESPACE))'; \
	    echo '  IMAGE_NAME      - Image name (default: $(IMAGE_NAME))'; \
	    echo '  IMAGE_TAG       - Image tag (default: $(IMAGE_TAG))'; \
	    echo ''; \
	    echo 'Examples:'; \
	    echo '  make build IMAGE_TAG=v1.0.0'; \
	    echo '  make push IMAGE_REGISTRY=quay.io IMAGE_NAMESPACE=myorg IMAGE_TAG=v1.0.0'; \
	    echo '  make clean'; \
	}
