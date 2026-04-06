#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-/workspace}"

if [[ -f "${WORKSPACE}/Cargo.toml" && -d "${WORKSPACE}/flutter" ]]; then
  REPO_ROOT="${WORKSPACE}"
else
  REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
fi

FLUTTER_HOME="${FLUTTER_HOME:-/opt/flutter}"
FLUTTER_BRIDGE_HOME="${FLUTTER_BRIDGE_HOME:-/opt/flutter-bridge}"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT}}"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_SDK_ROOT}/ndk/r28c}"
ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME}}"
VCPKG_ROOT="${VCPKG_ROOT:-/opt/vcpkg}"
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
CARGO_HOME="${CARGO_HOME:-${HOME}/.cargo}"

MAIN_FLUTTER="${FLUTTER_HOME}/bin/flutter"
BRIDGE_FLUTTER="${FLUTTER_BRIDGE_HOME}/bin/flutter"
FRB_CODEGEN="${CARGO_HOME}/bin/flutter_rust_bridge_codegen"

DEFAULT_ABI="${ANDROID_ABI:-arm64-v8a}"
DEFAULT_BUILD_MODE="${FLUTTER_BUILD_MODE:-release}"
OUTPUT_DIR_NAME="${ANDROID_UNSIGNED_APK_OUTPUT_DIR:-unsigned-apk}"
FORCE_BRIDGE_GEN="${FORCE_BRIDGE_GEN:-0}"

log() {
  printf '\n==> %s\n' "$*" >&2
}

step_echo() {
  printf '%s: %s\n' "$1" "$2" >&2
}

run_step() {
  local label="$1"
  shift

  step_echo "START" "${label}"
  if "$@"; then
    step_echo "SUCCESS" "${label}"
  else
    local status=$?
    step_echo "FAILED" "${label}"
    return "${status}"
  fi
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  rustdesk-android-build prepare
  rustdesk-android-build bridge
  rustdesk-android-build build-apk [abi] [build-mode]

Defaults:
  abi: arm64-v8a
  build-mode: release

Supported ABIs:
  arm64-v8a
  armeabi-v7a
  x86_64
  x86
EOF
}

ensure_repo_root() {
  if [[ ! -f "${REPO_ROOT}/Cargo.toml" || ! -d "${REPO_ROOT}/flutter" ]]; then
    printf 'ERROR: This script must run against the repository root.\n' >&2
    return 1
  fi
  if [[ ! -f "${REPO_ROOT}/libs/hbb_common/protos/message.proto" ]]; then
    printf 'ERROR: Missing libs/hbb_common submodule content. Initialize submodules before building.\n' >&2
    return 1
  fi
}

ensure_tooling() {
  [[ -x "${MAIN_FLUTTER}" ]] || {
    printf 'ERROR: Flutter SDK not found at %s\n' "${MAIN_FLUTTER}" >&2
    return 1
  }
  [[ -x "${BRIDGE_FLUTTER}" ]] || {
    printf 'ERROR: Bridge Flutter SDK not found at %s\n' "${BRIDGE_FLUTTER}" >&2
    return 1
  }
  [[ -x "${FRB_CODEGEN}" ]] || {
    printf 'ERROR: flutter_rust_bridge_codegen not found at %s\n' "${FRB_CODEGEN}" >&2
    return 1
  }
  [[ -x "${VCPKG_ROOT}/vcpkg" ]] || {
    printf 'ERROR: vcpkg not found at %s\n' "${VCPKG_ROOT}/vcpkg" >&2
    return 1
  }
  [[ -x "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" ]] || {
    printf 'ERROR: Android NDK not found at %s\n' "${ANDROID_NDK_HOME}" >&2
    return 1
  }
}

write_local_properties() {
  local pubspec_path="${REPO_ROOT}/flutter/pubspec.yaml"
  local local_properties_path="${REPO_ROOT}/flutter/android/local.properties"
  local version_line version_name version_code build_mode

  version_line="$(sed -n 's/^version:[[:space:]]*//p' "${pubspec_path}" | head -n 1)"
  version_name="${version_line%%+*}"
  version_code="${version_line##*+}"
  build_mode="${DEFAULT_BUILD_MODE}"

  if [[ -f "${local_properties_path}" ]]; then
    local existing_build_mode
    existing_build_mode="$(sed -n 's/^flutter\.buildMode=//p' "${local_properties_path}" | head -n 1)"
    if [[ -n "${existing_build_mode}" ]]; then
      build_mode="${existing_build_mode}"
    fi
  fi

  cat > "${local_properties_path}" <<EOF
sdk.dir=${ANDROID_SDK_ROOT}
flutter.sdk=${FLUTTER_HOME}
flutter.buildMode=${build_mode}
flutter.versionName=${version_name}
flutter.versionCode=${version_code}
EOF
}

bridge_files_missing() {
  [[ ! -f "${REPO_ROOT}/flutter/lib/generated_bridge.dart" || \
     ! -f "${REPO_ROOT}/flutter/lib/generated_bridge.freezed.dart" || \
     ! -f "${REPO_ROOT}/src/bridge_generated.rs" || \
     ! -f "${REPO_ROOT}/src/bridge_generated.io.rs" ]]
}

maybe_export_libclang() {
  local libclang_dir

  if [[ -n "${LIBCLANG_PATH:-}" ]]; then
    return
  fi

  libclang_dir="$(llvm-config --libdir 2>/dev/null || true)"
  if [[ -n "${libclang_dir}" ]]; then
    export LIBCLANG_PATH="${libclang_dir}"
  fi
}

restore_bridge_inputs() {
  local backup_dir="$1"
  cp "${backup_dir}/pubspec.yaml" "${REPO_ROOT}/flutter/pubspec.yaml"
  cp "${backup_dir}/pubspec.lock" "${REPO_ROOT}/flutter/pubspec.lock"
}

bridge_pub_get_step() {
  (
    cd "${REPO_ROOT}/flutter"
    sed -i -e 's/extended_text: 14.0.0/extended_text: 13.0.0/g' pubspec.yaml
    "${BRIDGE_FLUTTER}" pub get
  )
}

bridge_codegen_step() {
  maybe_export_libclang
  "${FRB_CODEGEN}" \
    --rust-input "${REPO_ROOT}/src/flutter_ffi.rs" \
    --dart-output "${REPO_ROOT}/flutter/lib/generated_bridge.dart" \
    --c-output "${REPO_ROOT}/flutter/macos/Runner/bridge_generated.h"

  [[ -f "${REPO_ROOT}/flutter/lib/generated_bridge.freezed.dart" ]] || {
    printf 'ERROR: flutter_rust_bridge_codegen did not produce flutter/lib/generated_bridge.freezed.dart\n' >&2
    return 1
  }
}

bridge_copy_headers_step() {
  local bridge_header="${REPO_ROOT}/flutter/macos/Runner/bridge_generated.h"
  cp "${bridge_header}" "${REPO_ROOT}/flutter/ios/Runner/bridge_generated.h"
}

main_flutter_pub_get_step() {
  (
    cd "${REPO_ROOT}/flutter"
    "${MAIN_FLUTTER}" pub get
  )
}

generate_bridge_files() {
  (
    set -euo pipefail

    local backup_dir=""

    cleanup() {
      if [[ -n "${backup_dir}" && -d "${backup_dir}" ]]; then
        restore_bridge_inputs "${backup_dir}"
        rm -rf "${backup_dir}"
      fi
    }

    backup_dir="$(mktemp -d)"
    cp "${REPO_ROOT}/flutter/pubspec.yaml" "${backup_dir}/pubspec.yaml"
    cp "${REPO_ROOT}/flutter/pubspec.lock" "${backup_dir}/pubspec.lock"
    trap cleanup EXIT

    log "Generating flutter-rust-bridge files with Flutter $(<"${FLUTTER_BRIDGE_HOME}/version")"
    run_step "Resolve bridge Flutter packages" bridge_pub_get_step
    run_step "Generate flutter-rust-bridge bindings" bridge_codegen_step
    run_step "Copy generated bridge headers" bridge_copy_headers_step
    run_step "Resolve main Flutter packages after bridge generation" main_flutter_pub_get_step
  )
}

ensure_bridge_files() {
  if [[ "${FORCE_BRIDGE_GEN}" == "1" || "${FORCE_BRIDGE_GEN}" == "true" ]] || bridge_files_missing; then
    generate_bridge_files
  else
    log "Bridge files already present"
  fi
}

ensure_flutter_packages() {
  log "Resolving Flutter packages"
  main_flutter_pub_get_step
}

map_abi() {
  local abi="$1"

  case "${abi}" in
    arm64-v8a)
      RUST_TARGET="aarch64-linux-android"
      FLUTTER_TARGET="android-arm64"
      JNI_DIR="arm64-v8a"
      NDK_LIB_DIR="aarch64-linux-android"
      NDK_SCRIPT="${REPO_ROOT}/flutter/ndk_arm64.sh"
      APK_NAME="app-arm64-v8a-${BUILD_MODE}.apk"
      ;;
    armeabi-v7a)
      RUST_TARGET="armv7-linux-androideabi"
      FLUTTER_TARGET="android-arm"
      JNI_DIR="armeabi-v7a"
      NDK_LIB_DIR="arm-linux-androideabi"
      NDK_SCRIPT="${REPO_ROOT}/flutter/ndk_arm.sh"
      APK_NAME="app-armeabi-v7a-${BUILD_MODE}.apk"
      ;;
    x86_64)
      RUST_TARGET="x86_64-linux-android"
      FLUTTER_TARGET="android-x64"
      JNI_DIR="x86_64"
      NDK_LIB_DIR="x86_64-linux-android"
      NDK_SCRIPT="${REPO_ROOT}/flutter/ndk_x64.sh"
      APK_NAME="app-x86_64-${BUILD_MODE}.apk"
      ;;
    x86)
      RUST_TARGET="i686-linux-android"
      FLUTTER_TARGET="android-x86"
      JNI_DIR="x86"
      NDK_LIB_DIR="i686-linux-android"
      NDK_SCRIPT="${REPO_ROOT}/flutter/ndk_x86.sh"
      APK_NAME="app-x86-${BUILD_MODE}.apk"
      ;;
    *)
      fail "Unsupported ABI: ${abi}"
      ;;
  esac
}

prepare_jni_libs() {
  local jni_path="${REPO_ROOT}/flutter/android/app/src/main/jniLibs/${JNI_DIR}"

  mkdir -p "${jni_path}"
  cp "${REPO_ROOT}/target/${RUST_TARGET}/release/liblibrustdesk.so" "${jni_path}/librustdesk.so"
  cp "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/${NDK_LIB_DIR}/libc++_shared.so" "${jni_path}/"
}

version_name_from_pubspec() {
  sed -n 's/^version:[[:space:]]*//p' "${REPO_ROOT}/flutter/pubspec.yaml" | head -n 1 | cut -d'+' -f1
}

build_android_deps_step() {
  local abi="$1"
  (
    cd "${REPO_ROOT}"
    bash ./flutter/build_android_deps.sh "${abi}"
  )
}

build_rust_library_step() {
  (
    cd "${REPO_ROOT}"
    rustup target add "${RUST_TARGET}"
    bash "${NDK_SCRIPT}"
  )
}

flutter_build_apk_step() {
  (
    set -euo pipefail

    local app_gradle_backup=""
    local gradle_props_backup=""

    cleanup() {
      if [[ -n "${app_gradle_backup}" && -f "${app_gradle_backup}" ]]; then
        cp "${app_gradle_backup}" "${REPO_ROOT}/flutter/android/app/build.gradle"
      fi
      if [[ -n "${gradle_props_backup}" && -f "${gradle_props_backup}" ]]; then
        cp "${gradle_props_backup}" "${REPO_ROOT}/flutter/android/gradle.properties"
      fi
      if [[ -n "${app_gradle_backup}" ]]; then
        rm -f "${app_gradle_backup}"
      fi
      if [[ -n "${gradle_props_backup}" ]]; then
        rm -f "${gradle_props_backup}"
      fi
    }

    app_gradle_backup="$(mktemp)"
    gradle_props_backup="$(mktemp)"
    cp "${REPO_ROOT}/flutter/android/app/build.gradle" "${app_gradle_backup}"
    cp "${REPO_ROOT}/flutter/android/gradle.properties" "${gradle_props_backup}"
    trap cleanup EXIT

    sed -i 's/org.gradle.jvmargs=-Xmx1024M/org.gradle.jvmargs=-Xmx2g/' "${REPO_ROOT}/flutter/android/gradle.properties"
    sed -i 's/signingConfigs.release/signingConfigs.debug/' "${REPO_ROOT}/flutter/android/app/build.gradle"

    cd "${REPO_ROOT}/flutter"
    export PATH="${JAVA_HOME}/bin:${PATH}"
    "${MAIN_FLUTTER}" build apk "--${BUILD_MODE}" --target-platform "${FLUTTER_TARGET}" --split-per-abi
  )
}

collect_apk_output_step() {
  local output_dir version_name output_apk source_apk

  output_dir="${REPO_ROOT}/${OUTPUT_DIR_NAME}"
  version_name="$(version_name_from_pubspec)"
  source_apk="${REPO_ROOT}/flutter/build/app/outputs/flutter-apk/${APK_NAME}"
  output_apk="${output_dir}/rustdesk-${version_name}-${abi}.apk"

  mkdir -p "${output_dir}"
  [[ -f "${source_apk}" ]] || {
    printf 'ERROR: Expected APK output not found at %s\n' "${source_apk}" >&2
    return 1
  }
  cp "${source_apk}" "${output_apk}"

  log "APK available at ${output_apk}"
}

build_apk() {
  local abi="$1"

  BUILD_MODE="${2:-${DEFAULT_BUILD_MODE}}"
  map_abi "${abi}"

  run_step "Install Android native dependencies for ${abi}" build_android_deps_step "${abi}"
  run_step "Build Rust library for ${abi}" build_rust_library_step
  run_step "Prepare JNI libraries for ${abi}" prepare_jni_libs
  run_step "Build Flutter APK for ${abi} (${BUILD_MODE})" flutter_build_apk_step
  run_step "Collect APK output for ${abi}" collect_apk_output_step
}

prepare_workspace() {
  run_step "Validate repository layout" ensure_repo_root
  run_step "Validate Android build tooling" ensure_tooling
  run_step "Write Android local.properties" write_local_properties
  run_step "Ensure bridge files exist" ensure_bridge_files
  run_step "Resolve Flutter packages" ensure_flutter_packages
}

main() {
  local command="${1:-}"
  local abi build_mode

  case "${command}" in
    prepare)
      prepare_workspace
      ;;
    bridge)
      ensure_repo_root
      ensure_tooling
      write_local_properties
      generate_bridge_files
      ;;
    build-apk)
      abi="${2:-${DEFAULT_ABI}}"
      build_mode="${3:-${DEFAULT_BUILD_MODE}}"
      prepare_workspace
      build_apk "${abi}" "${build_mode}"
      ;;
    ""|-h|--help|help)
      usage
      ;;
    *)
      usage
      fail "Unknown command: ${command}"
      ;;
  esac
}

main "$@"
