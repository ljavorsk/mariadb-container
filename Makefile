# Variables are documented in hack/build.sh.
BASE_IMAGE_NAME = mariadb garbd
VERSIONS = 10.3 10.5
OPENSHIFT_NAMESPACES = 
DOCKER_BUILD_CONTEXT = ..

# HACK:  Ensure that 'git pull' for old clones doesn't cause confusion.
# New clones should use '--recursive'.
.PHONY: $(shell test -f common/common.mk || echo >&2 'Please do "git submodule update --init" first.')

include common/common.mk
