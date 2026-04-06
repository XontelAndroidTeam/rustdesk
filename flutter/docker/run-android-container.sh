#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_DEFAULT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"

IMAGE_NAME="${IMAGE_NAME:-rustdesk-android-env}"
WORKSPACE_HOST_PATH="${WORKSPACE_HOST_PATH:-${REPO_ROOT_DEFAULT}}"
OUTPUT_HOST_PATH="${OUTPUT_HOST_PATH:-${WORKSPACE_HOST_PATH}/unsigned-apk}"
CACHE_ROOT="${CACHE_ROOT:-${XDG_CACHE_HOME:-${HOME}/.cache}/rustdesk-android-docker}"
GRADLE_CACHE_HOST_PATH="${GRADLE_CACHE_HOST_PATH:-${CACHE_ROOT}/gradle}"
PUB_CACHE_HOST_PATH="${PUB_CACHE_HOST_PATH:-${CACHE_ROOT}/pub-cache}"
CARGO_REGISTRY_HOST_PATH="${CARGO_REGISTRY_HOST_PATH:-${CACHE_ROOT}/cargo-registry}"
CARGO_GIT_HOST_PATH="${CARGO_GIT_HOST_PATH:-${CACHE_ROOT}/cargo-git}"
TARGET_HOST_PATH="${TARGET_HOST_PATH:-${CACHE_ROOT}/target}"
AUTO_PREPARE="${AUTO_PREPARE:-0}"

declare -a EXTRA_BINDS=()
declare -a CONTAINER_COMMAND=()

usage() {
  cat <<'EOF'
Usage:
  ./flutter/docker/run-android-container.sh [options] [-- <container command>]

Options:
  --image NAME             Docker image name. Default: rustdesk-android-env
  --workspace PATH         Host path mounted to /workspace
  --output PATH            Host path mounted to /workspace/unsigned-apk
  --cache-root PATH        Host cache root for Gradle, Pub, Cargo, and target
  --bind HOST:CONTAINER    Extra bind mount. Repeatable.
  --auto-prepare           Set RUSTDESK_AUTO_PREPARE=1 inside the container
  -h, --help               Show this help

Examples:
  ./flutter/docker/run-android-container.sh
  ./flutter/docker/run-android-container.sh --auto-prepare -- rustdesk-android-build build-apk arm64-v8a
  ./flutter/docker/run-android-container.sh --bind /data/shared:/host-share -- bash
EOF
}

log() {
  printf '%s\n' "$*" >&2
}

abs_path() {
  local path="$1"

  if [[ -d "$path" ]]; then
    (cd "$path" && pwd -P)
  else
    local dir
    dir="$(dirname "$path")"
    local base
    base="$(basename "$path")"
    mkdir -p "$dir"
    dir="$(cd "$dir" && pwd -P)"
    printf '%s/%s\n' "$dir" "$base"
  fi
}

ensure_dir() {
  local path="$1"
  mkdir -p "$path"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)
        IMAGE_NAME="$2"
        shift 2
        ;;
      --workspace)
        WORKSPACE_HOST_PATH="$2"
        shift 2
        ;;
      --output)
        OUTPUT_HOST_PATH="$2"
        shift 2
        ;;
      --cache-root)
        CACHE_ROOT="$2"
        GRADLE_CACHE_HOST_PATH="${CACHE_ROOT}/gradle"
        PUB_CACHE_HOST_PATH="${CACHE_ROOT}/pub-cache"
        CARGO_REGISTRY_HOST_PATH="${CACHE_ROOT}/cargo-registry"
        CARGO_GIT_HOST_PATH="${CACHE_ROOT}/cargo-git"
        TARGET_HOST_PATH="${CACHE_ROOT}/target"
        shift 2
        ;;
      --bind)
        EXTRA_BINDS+=("$2")
        shift 2
        ;;
      --auto-prepare)
        AUTO_PREPARE=1
        shift
        ;;
      --)
        shift
        CONTAINER_COMMAND=("$@")
        break
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        CONTAINER_COMMAND=("$@")
        break
        ;;
    esac
  done
}

prepare_paths() {
  WORKSPACE_HOST_PATH="$(abs_path "$WORKSPACE_HOST_PATH")"
  OUTPUT_HOST_PATH="$(abs_path "$OUTPUT_HOST_PATH")"
  GRADLE_CACHE_HOST_PATH="$(abs_path "$GRADLE_CACHE_HOST_PATH")"
  PUB_CACHE_HOST_PATH="$(abs_path "$PUB_CACHE_HOST_PATH")"
  CARGO_REGISTRY_HOST_PATH="$(abs_path "$CARGO_REGISTRY_HOST_PATH")"
  CARGO_GIT_HOST_PATH="$(abs_path "$CARGO_GIT_HOST_PATH")"
  TARGET_HOST_PATH="$(abs_path "$TARGET_HOST_PATH")"

  ensure_dir "$WORKSPACE_HOST_PATH"
  ensure_dir "$OUTPUT_HOST_PATH"
  ensure_dir "$GRADLE_CACHE_HOST_PATH"
  ensure_dir "$PUB_CACHE_HOST_PATH"
  ensure_dir "$CARGO_REGISTRY_HOST_PATH"
  ensure_dir "$CARGO_GIT_HOST_PATH"
  ensure_dir "$TARGET_HOST_PATH"
}

run_container() {
  local -a docker_args
  docker_args=(
    run
    --rm
    -it
    -e WORKSPACE=/workspace
    -v "${WORKSPACE_HOST_PATH}:/workspace"
    -v "${OUTPUT_HOST_PATH}:/workspace/unsigned-apk"
    -v "${GRADLE_CACHE_HOST_PATH}:/opt/.gradle"
    -v "${PUB_CACHE_HOST_PATH}:/opt/.pub-cache"
    -v "${CARGO_REGISTRY_HOST_PATH}:/opt/.cargo/registry"
    -v "${CARGO_GIT_HOST_PATH}:/opt/.cargo/git"
    -v "${TARGET_HOST_PATH}:/workspace/target"
  )

  if [[ "${AUTO_PREPARE}" == "1" || "${AUTO_PREPARE}" == "true" ]]; then
    docker_args+=(-e RUSTDESK_AUTO_PREPARE=1)
  fi

  for bind_spec in "${EXTRA_BINDS[@]}"; do
    docker_args+=(-v "${bind_spec}")
  done

  docker_args+=("${IMAGE_NAME}")

  if [[ ${#CONTAINER_COMMAND[@]} -eq 0 ]]; then
    CONTAINER_COMMAND=(bash)
  fi

  docker_args+=("${CONTAINER_COMMAND[@]}")

  log "Workspace mount: ${WORKSPACE_HOST_PATH} -> /workspace"
  log "Output mount: ${OUTPUT_HOST_PATH} -> /workspace/unsigned-apk"
  log "Gradle cache: ${GRADLE_CACHE_HOST_PATH} -> /opt/.gradle"
  log "Pub cache: ${PUB_CACHE_HOST_PATH} -> /opt/.pub-cache"
  log "Cargo registry cache: ${CARGO_REGISTRY_HOST_PATH} -> /opt/.cargo/registry"
  log "Cargo git cache: ${CARGO_GIT_HOST_PATH} -> /opt/.cargo/git"
  log "Target cache: ${TARGET_HOST_PATH} -> /workspace/target"
  for bind_spec in "${EXTRA_BINDS[@]}"; do
    log "Extra bind: ${bind_spec}"
  done

  docker "${docker_args[@]}"
}

main() {
  parse_args "$@"
  prepare_paths
  run_container
}

main "$@"
