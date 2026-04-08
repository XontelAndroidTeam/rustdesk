#!/usr/bin/env bash

# Exit on command failures, on unset variables, and on failed pipeline segments.
set -euo pipefail

# Default paths and fallback build metadata used inside the container.
# The entrypoint runs against a bind-mounted repo at /workspace unless overridden.
WORKSPACE="${WORKSPACE:-/workspace}"
# These fallbacks are only used when local.properties does not already provide values.
DEFAULT_BUILD_MODE="${FLUTTER_BUILD_MODE:-release}"
DEFAULT_VERSION_NAME="${RUSTDESK_VERSION_NAME:-1.4.6}"
DEFAULT_VERSION_CODE="${RUSTDESK_VERSION_CODE:-64}"

# Create the minimal Android user config expected by sdkmanager and related tools.
ensure_android_runtime_files() {
  # Some Android tools assume ~/.android exists even in ephemeral containers.
  mkdir -p "${HOME}/.android"
  # repositories.cfg can be empty; it only needs to exist to silence warnings.
  : > "${HOME}/.android/repositories.cfg"
}

# Mark bind-mounted repositories as safe so Git works under the container user.
mark_safe_directories() {
  # Skip Git setup entirely if the image does not have git available.
  if ! command -v git >/dev/null 2>&1; then
    return
  fi

  # The main repo is bind-mounted from the host, so Git may consider ownership suspicious.
  if [[ -e "${WORKSPACE}/.git" ]]; then
    # Ignore failures here so container startup does not fail on duplicate entries or Git config quirks.
    git config --global --add safe.directory "${WORKSPACE}" || true
  fi

  # hbb_common may be its own Git repo or submodule, so mark it separately.
  if [[ -e "${WORKSPACE}/libs/hbb_common/.git" ]]; then
    git config --global --add safe.directory "${WORKSPACE}/libs/hbb_common" || true
  fi
}

# Read the version string from pubspec.yaml if the workspace has one.
read_pubspec_version() {
  local pubspec_path="$1"
  local version_line

  # If the Flutter workspace is absent, let the caller fall back to defaults.
  if [[ ! -f "${pubspec_path}" ]]; then
    return
  fi

  # Extract the first "version:" entry without the key prefix.
  version_line="$(sed -n 's/^version:[[:space:]]*//p' "${pubspec_path}" | head -n 1)"
  if [[ -z "${version_line}" ]]; then
    return
  fi

  # Print so callers can capture the parsed version string.
  printf '%s\n' "${version_line}"
}

# Write flutter/android/local.properties for the mounted workspace.
write_local_properties() {
  # local.properties must point Gradle at the SDKs installed inside the container, not on the host.
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

  # If the mounted workspace is not a Flutter Android project, there is nothing to write.
  if [[ ! -d "${android_dir}" ]]; then
    return
  fi

  # Prefer version metadata from pubspec.yaml when available.
  pubspec_version="$(read_pubspec_version "${pubspec_path}" || true)"
  if [[ -n "${pubspec_version}" ]]; then
    # Flutter uses "name+code", for example "1.4.6+64".
    version_name="${pubspec_version%%+*}"
    if [[ "${pubspec_version}" == *"+"* ]]; then
      version_code="${pubspec_version##*+}"
    fi
  fi

  # Preserve existing explicit values if a previous run already wrote local.properties.
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

  # Ensure the Android directory exists before overwriting local.properties.
  mkdir -p "${android_dir}"
  # Rewrite the file so Gradle always resolves SDK paths inside the current container.
  cat > "${local_properties_path}" <<EOF
sdk.dir=${ANDROID_SDK_ROOT}
flutter.sdk=${FLUTTER_HOME}
flutter.buildMode=${build_mode}
flutter.versionName=${version_name}
flutter.versionCode=${version_code}
EOF
}

# Bootstrap the container, optionally prepare the workspace, then run the command.
main() {
  # Do the minimal environment setup every container start, even for interactive shells.
  ensure_android_runtime_files
  mark_safe_directories
  write_local_properties

  # When requested by the host launcher, run the prepare phase before the main command.
  if [[ "${RUSTDESK_AUTO_PREPARE:-0}" == "1" || "${RUSTDESK_AUTO_PREPARE:-0}" == "true" ]]; then
    # Only do this when the build helper exists and /workspace looks like the repo root.
    if command -v rustdesk-android-build >/dev/null 2>&1 && [[ -f "${WORKSPACE}/Cargo.toml" ]]; then
      rustdesk-android-build prepare
    fi
  fi

  # With no command, drop into an interactive shell for debugging.
  if [[ $# -eq 0 ]]; then
    exec bash
  fi

  # Replace the entrypoint process so signals go directly to the requested command.
  exec "$@"
}

main "$@"
