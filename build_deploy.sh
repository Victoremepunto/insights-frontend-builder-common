#!/bin/bash

load_cicd_helper_functions() {

    local LIBRARY_TO_LOAD=${1:-all}
    local CICD_TOOLS_REPO_BRANCH='main'
    local CICD_TOOLS_REPO_ORG='RedHatInsights'
    local CICD_TOOLS_URL="https://raw.githubusercontent.com/${CICD_TOOLS_REPO_ORG}/cicd-tools/${CICD_TOOLS_REPO_BRANCH}/src/bootstrap.sh"
    set -e
    # shellcheck source=/dev/null
    source <(curl -sSL "$CICD_TOOLS_URL") "$LIBRARY_TO_LOAD"
    set +e
}
load_cicd_helper_functions container_engine

# --------------------------------------------
# Export vars for helper scripts to use
# --------------------------------------------
IMAGE="quay.io/cloudservices/releaser"
IMAGE_TAG=$(get_7_chars_commit_hash)
DOCKERFILE='src/releaser.Dockerfile'

set -exv
#TODO - handle in library - is this really needed ??
#DOCKER_CONF="$PWD/.docker"
#mkdir -p "$DOCKER_CONF"

if ! local_build; then
    if [[ -z "$QUAY_USER" || -z "$QUAY_TOKEN" ]]; then
        echo "QUAY_USER and QUAY_TOKEN must be set"
        exit 1
    fi

    if [[ -z "$RH_REGISTRY_USER" || -z "$RH_REGISTRY_TOKEN" ]]; then
        echo "RH_REGISTRY_USER and RH_REGISTRY_TOKEN must be set"
        exit 1
    fi

    container_engine_cmd login -u="$QUAY_USER" -p="$QUAY_TOKEN" quay.io
    container_engine_cmd login -u="$RH_REGISTRY_USER" -p="$RH_REGISTRY_TOKEN" registry.redhat.io
fi

container_engine_cmd build -t "${IMAGE}:${IMAGE_TAG}" -f "$DOCKERFILE"

if ! local_build; then
    container_engine_cmd push "${IMAGE}:${IMAGE_TAG}"
fi
