#!/usr/bin/env bash

set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
DEFAULT_BUILD_MODE="${FLUTTER_BUILD_MODE:-release}"
DEFAULT_VERSION_NAME="${RUSTDESK_VERSION_NAME:-1.4.6}"
DEFAULT_VERSION_CODE="${RUSTDESK_VERSION_CODE:-64}"

ensure_android_runtime_files() {
  mkdir -p "${HOME}/.android"
  : > "${HOME}/.android/repositories.cfg"
}

mark_safe_directories() {
  if ! command -v git >/dev/null 2>&1; then
    return
  fi

  if [[ -e "${WORKSPACE}/.git" ]]; then
    git config --global --add safe.directory "${WORKSPACE}" || true
  fi

  if [[ -e "${WORKSPACE}/libs/hbb_common/.git" ]]; then
    git config --global --add safe.directory "${WORKSPACE}/libs/hbb_common" || true
  fi
}

read_pubspec_version() {
  local pubspec_path="$1"
  local version_line

  if [[ ! -f "${pubspec_path}" ]]; then
    return
  fi

  version_line="$(sed -n 's/^version:[[:space:]]*//p' "${pubspec_path}" | head -n 1)"
  if [[ -z "${version_line}" ]]; then
    return
  fi

  printf '%s\n' "${version_line}"
}

write_local_properties() {
  local flutter_dir="${WORKSPACE}/flutter"
  local android_dir="${flutter_dir}/android"
  local local_properties_path="${android_dir}/local.properties"
  local pubspec_path="${flutter_dir}/pubspec.yaml"
  local build_mode="${DEFAULT_BUILD_MODE}"
  local version_name="${DEFAULT_VERSION_NAME}"
  local version_code="${DEFAULT_VERSION_CODE}"
  local pubspec_version
  local existing_build_mode
  local existing_version_name
  local existing_version_code

  if [[ ! -d "${android_dir}" ]]; then
    return
  fi

  pubspec_version="$(read_pubspec_version "${pubspec_path}" || true)"
  if [[ -n "${pubspec_version}" ]]; then
    version_name="${pubspec_version%%+*}"
    if [[ "${pubspec_version}" == *"+"* ]]; then
      version_code="${pubspec_version##*+}"
    fi
  fi

  if [[ -f "${local_properties_path}" ]]; then
    existing_build_mode="$(sed -n 's/^flutter\.buildMode=//p' "${local_properties_path}" | head -n 1)"
    existing_version_name="$(sed -n 's/^flutter\.versionName=//p' "${local_properties_path}" | head -n 1)"
    existing_version_code="$(sed -n 's/^flutter\.versionCode=//p' "${local_properties_path}" | head -n 1)"

    if [[ -n "${existing_build_mode}" ]]; then
      build_mode="${existing_build_mode}"
    fi
    if [[ -n "${existing_version_name}" ]]; then
      version_name="${existing_version_name}"
    fi
    if [[ -n "${existing_version_code}" ]]; then
      version_code="${existing_version_code}"
    fi
  fi

  mkdir -p "${android_dir}"
  cat > "${local_properties_path}" <<EOF
sdk.dir=${ANDROID_SDK_ROOT}
flutter.sdk=${FLUTTER_HOME}
flutter.buildMode=${build_mode}
flutter.versionName=${version_name}
flutter.versionCode=${version_code}
EOF
}

main() {
  ensure_android_runtime_files
  mark_safe_directories
  write_local_properties

  if [[ "${RUSTDESK_AUTO_PREPARE:-0}" == "1" || "${RUSTDESK_AUTO_PREPARE:-0}" == "true" ]]; then
    if command -v rustdesk-android-build >/dev/null 2>&1 && [[ -f "${WORKSPACE}/Cargo.toml" ]]; then
      rustdesk-android-build prepare
    fi
  fi

  if [[ $# -eq 0 ]]; then
    exec bash
  fi

  exec "$@"
}

main "$@"
