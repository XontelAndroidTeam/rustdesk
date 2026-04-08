#!/usr/bin/env bash

# Exit on command failures, on unset variables, and on failed pipeline segments.
set -euo pipefail

# Resolve the repo root and core tool locations for containerized builds.
# SCRIPT_DIR is only used for the fallback repo-root calculation below.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# /workspace is the bind-mounted host repo path used by the Docker launcher.
WORKSPACE="${WORKSPACE:-/workspace}"

# Prefer the bind-mounted workspace when it looks like the repo root.
if [[ -f "${WORKSPACE}/Cargo.toml" && -d "${WORKSPACE}/flutter" ]]; then
  REPO_ROOT="${WORKSPACE}"
else
  # Fallback makes the script usable outside the Docker image too.
  REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
fi

# Toolchain roots are expected to come from the Docker image environment.
FLUTTER_HOME="${FLUTTER_HOME:-/opt/flutter}"
FLUTTER_BRIDGE_HOME="${FLUTTER_BRIDGE_HOME:-/opt/flutter-bridge}"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT}}"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_SDK_ROOT}/ndk/r28c}"
ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME}}"
VCPKG_ROOT="${VCPKG_ROOT:-/opt/vcpkg}"
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
CARGO_HOME="${CARGO_HOME:-${HOME}/.cargo}"

# Keep the frequently-used binary paths in named variables to avoid repeating long absolute paths.
MAIN_FLUTTER="${FLUTTER_HOME}/bin/flutter"
BRIDGE_FLUTTER="${FLUTTER_BRIDGE_HOME}/bin/flutter"
FRB_CODEGEN="${CARGO_HOME}/bin/flutter_rust_bridge_codegen"

# Defaults let callers omit ABI, build mode, and output directory configuration.
DEFAULT_ABI="${ANDROID_ABI:-arm64-v8a}"
DEFAULT_BUILD_MODE="${FLUTTER_BUILD_MODE:-release}"
OUTPUT_DIR_NAME="${ANDROID_UNSIGNED_APK_OUTPUT_DIR:-unsigned-apk}"
FORCE_BRIDGE_GEN="${FORCE_BRIDGE_GEN:-0}"

TIMING_SUMMARY_ENABLED=0
TIMING_SUMMARY_PRINTED=0
BUILD_TOTAL_START_MS=""
declare -a TIMING_LABELS=()
declare -a TIMING_DURATIONS_MS=()

# Shared logging and error helpers for build steps.
log() {
  printf '\n==> %s\n' "$*" >&2
}

now_ms() {
  date +%s%3N
}

record_timing() {
  local label="$1"
  local duration_ms="$2"

  TIMING_LABELS+=("${label}")
  TIMING_DURATIONS_MS+=("${duration_ms}")
}

format_duration_ms() {
  local duration_ms="$1"
  printf '%d.%01ds' "$((duration_ms / 1000))" "$(((duration_ms % 1000) / 100))"
}

print_timing_summary() {
  local total_ms="0"
  local i

  if [[ "${TIMING_SUMMARY_ENABLED}" != "1" || "${TIMING_SUMMARY_PRINTED}" == "1" ]]; then
    return
  fi

  TIMING_SUMMARY_PRINTED=1

  if [[ -n "${BUILD_TOTAL_START_MS}" ]]; then
    total_ms="$(( $(now_ms) - BUILD_TOTAL_START_MS ))"
  fi

  printf '\n==> Build timing summary\n' >&2
  printf '%-32s %s\n' "TOTAL" "$(format_duration_ms "${total_ms}")" >&2

  for ((i = 0; i < ${#TIMING_LABELS[@]}; i++)); do
    printf '%-32s %s\n' "${TIMING_LABELS[$i]}" "$(format_duration_ms "${TIMING_DURATIONS_MS[$i]}")" >&2
  done
}

time_block() {
  local label="$1"
  local start_ms end_ms status
  shift

  start_ms="$(now_ms)"
  if "$@"; then
    status=0
  else
    status=$?
  fi
  end_ms="$(now_ms)"

  record_timing "${label}" "$((end_ms - start_ms))"
  return "${status}"
}

step_echo() {
  printf '%s: %s\n' "$1" "$2" >&2
}

run_step() {
  local label="$1"
  local start_ms end_ms
  shift

  # Emit consistent START/SUCCESS/FAILED messages around each significant step.
  start_ms="$(now_ms)"
  step_echo "START" "${label}"
  if "$@"; then
    end_ms="$(now_ms)"
    record_timing "${label}" "$((end_ms - start_ms))"
    step_echo "SUCCESS" "${label}"
  else
    local status=$?
    end_ms="$(now_ms)"
    record_timing "${label}" "$((end_ms - start_ms))"
    step_echo "FAILED" "${label}"
    return "${status}"
  fi
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# CLI usage and upfront validation of the mounted workspace and toolchain.
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
  # The build scripts expect to run from the repository root, not only from flutter/.
  if [[ ! -f "${REPO_ROOT}/Cargo.toml" || ! -d "${REPO_ROOT}/flutter" ]]; then
    printf 'ERROR: This script must run against the repository root.\n' >&2
    return 1
  fi
  # hbb_common content is required during the Rust build; a missing submodule would fail later with less context.
  if [[ ! -f "${REPO_ROOT}/libs/hbb_common/protos/message.proto" ]]; then
    printf 'ERROR: Missing libs/hbb_common submodule content. Initialize submodules before building.\n' >&2
    return 1
  fi
}

ensure_tooling() {
  # Fail early if any required SDK or helper is absent from the image.
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

# Prepare Flutter metadata and generate bridge files when required.
write_local_properties() {
  local pubspec_path="${REPO_ROOT}/flutter/pubspec.yaml"
  local local_properties_path="${REPO_ROOT}/flutter/android/local.properties"
  local version_line version_name version_code build_mode

  # Flutter stores the app version in pubspec.yaml as "name+code".
  version_line="$(sed -n 's/^version:[[:space:]]*//p' "${pubspec_path}" | head -n 1)"
  version_name="${version_line%%+*}"
  version_code="${version_line##*+}"
  build_mode="${DEFAULT_BUILD_MODE}"

  if [[ -f "${local_properties_path}" ]]; then
    local existing_build_mode
    # Preserve an existing explicit build mode if one was already written to local.properties.
    existing_build_mode="$(sed -n 's/^flutter\.buildMode=//p' "${local_properties_path}" | head -n 1)"
    if [[ -n "${existing_build_mode}" ]]; then
      build_mode="${existing_build_mode}"
    fi
  fi

  # Always point Gradle at the SDKs available inside the current container.
  cat > "${local_properties_path}" <<EOF
sdk.dir=${ANDROID_SDK_ROOT}
flutter.sdk=${FLUTTER_HOME}
flutter.buildMode=${build_mode}
flutter.versionName=${version_name}
flutter.versionCode=${version_code}
EOF
}

bridge_files_missing() {
  # Any missing generated bridge file means the bridge generation phase must run again.
  [[ ! -f "${REPO_ROOT}/flutter/lib/generated_bridge.dart" || \
     ! -f "${REPO_ROOT}/flutter/lib/generated_bridge.freezed.dart" || \
     ! -f "${REPO_ROOT}/src/bridge_generated.rs" || \
     ! -f "${REPO_ROOT}/src/bridge_generated.io.rs" ]]
}

maybe_export_libclang() {
  local libclang_dir

  # Respect an explicit LIBCLANG_PATH from the caller or the image.
  if [[ -n "${LIBCLANG_PATH:-}" ]]; then
    return
  fi

  # flutter_rust_bridge_codegen can need libclang; llvm-config is the most reliable way to find it in the image.
  libclang_dir="$(llvm-config --libdir 2>/dev/null || true)"
  if [[ -n "${libclang_dir}" ]]; then
    export LIBCLANG_PATH="${libclang_dir}"
  fi
}

restore_bridge_inputs() {
  local backup_dir="$1"
  # Bridge generation temporarily mutates pubspec files, so restore them before leaving the helper subshell.
  cp "${backup_dir}/pubspec.yaml" "${REPO_ROOT}/flutter/pubspec.yaml"
  cp "${backup_dir}/pubspec.lock" "${REPO_ROOT}/flutter/pubspec.lock"
}

bridge_pub_get_step() {
  (
    # Run inside flutter/ so pub resolves packages for the Flutter app.
    cd "${REPO_ROOT}/flutter"
    # The bridge Flutter SDK expects an older extended_text version during codegen.
    sed -i -e 's/extended_text: 14.0.0/extended_text: 13.0.0/g' pubspec.yaml
    # Use the dedicated bridge Flutter SDK rather than the main app SDK for code generation compatibility.
    "${BRIDGE_FLUTTER}" pub get
  )
}

bridge_codegen_step() {
  # Ensure clang discovery is set before invoking flutter_rust_bridge_codegen.
  maybe_export_libclang
  "${FRB_CODEGEN}" \
    --rust-input "${REPO_ROOT}/src/flutter_ffi.rs" \
    --dart-output "${REPO_ROOT}/flutter/lib/generated_bridge.dart" \
    --c-output "${REPO_ROOT}/flutter/macos/Runner/bridge_generated.h"

  # The generated freezed file is a useful sentinel that bridge codegen really completed.
  [[ -f "${REPO_ROOT}/flutter/lib/generated_bridge.freezed.dart" ]] || {
    printf 'ERROR: flutter_rust_bridge_codegen did not produce flutter/lib/generated_bridge.freezed.dart\n' >&2
    return 1
  }
}

bridge_copy_headers_step() {
  local bridge_header="${REPO_ROOT}/flutter/macos/Runner/bridge_generated.h"
  # iOS reuses the generated header produced during bridge generation.
  cp "${bridge_header}" "${REPO_ROOT}/flutter/ios/Runner/bridge_generated.h"
}

main_flutter_pub_get_step() {
  (
    # Restore package resolution using the main Flutter SDK after any bridge-specific work.
    cd "${REPO_ROOT}/flutter"
    "${MAIN_FLUTTER}" pub get
  )
}

generate_bridge_files() {
  (
    # Keep backup files, trap handlers, and temporary pubspec edits scoped to this helper subshell.
    set -euo pipefail

    local backup_dir=""

    cleanup() {
      # Restore the original pubspec inputs even if bridge generation fails midway.
      if [[ -n "${backup_dir}" && -d "${backup_dir}" ]]; then
        restore_bridge_inputs "${backup_dir}"
        rm -rf "${backup_dir}"
      fi
    }

    # Back up the pubspec inputs before applying the temporary bridge-generation dependency tweak.
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
  # Force regeneration when requested, otherwise only generate if the expected outputs are missing.
  if [[ "${FORCE_BRIDGE_GEN}" == "1" || "${FORCE_BRIDGE_GEN}" == "true" ]] || bridge_files_missing; then
    generate_bridge_files
  else
    log "Bridge files already present"
  fi
}

ensure_flutter_packages() {
  # Even when bridge files already exist, make sure the main Flutter dependencies are resolved.
  log "Resolving Flutter packages"
  main_flutter_pub_get_step
}

# Map an ABI to Rust/Flutter targets and run the per-ABI APK build steps.
map_abi() {
  local abi="$1"

  # Populate all per-ABI variables used by the later native and Flutter build steps.
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

  # Flutter packages the native Rust library from jniLibs, so copy the built .so there.
  mkdir -p "${jni_path}"
  cp "${REPO_ROOT}/target/${RUST_TARGET}/release/liblibrustdesk.so" "${jni_path}/librustdesk.so"
  # The NDK shared C++ runtime must travel with the APK for the native library to load.
  cp "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/${NDK_LIB_DIR}/libc++_shared.so" "${jni_path}/"
}

version_name_from_pubspec() {
  # The final APK filename uses only the version name, not the +build number.
  sed -n 's/^version:[[:space:]]*//p' "${REPO_ROOT}/flutter/pubspec.yaml" | head -n 1 | cut -d'+' -f1
}

build_android_deps_step() {
  local abi="$1"
  (
    # Delegate Android-side native dependency builds to the existing repo helper.
    cd "${REPO_ROOT}"
    bash ./flutter/build_android_deps.sh "${abi}"
  )
}

build_rust_library_step() {
  (
    # Make sure the Rust target is installed in case the image or cache was reused in a partial state.
    cd "${REPO_ROOT}"
    rustup target add "${RUST_TARGET}"
    # The per-ABI NDK helper builds librustdesk.so with cargo-ndk.
    bash "${NDK_SCRIPT}"
  )
}

flutter_build_apk_step() {
  (
    # Keep temporary Gradle edits scoped to this subshell and always restore them afterward.
    set -euo pipefail

    local app_gradle_backup=""
    local gradle_props_backup=""

    cleanup() {
      # Restore the original Android Gradle files after the build, whether it succeeded or failed.
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

    # Snapshot the Gradle files before the temporary in-place edits below.
    app_gradle_backup="$(mktemp)"
    gradle_props_backup="$(mktemp)"
    cp "${REPO_ROOT}/flutter/android/app/build.gradle" "${app_gradle_backup}"
    cp "${REPO_ROOT}/flutter/android/gradle.properties" "${gradle_props_backup}"
    trap cleanup EXIT

    # Increase the Gradle heap to reduce OOM risk in containerized builds.
    sed -i 's/org.gradle.jvmargs=-Xmx1024M/org.gradle.jvmargs=-Xmx2g/' "${REPO_ROOT}/flutter/android/gradle.properties"
    # Build unsigned output by reusing debug signing instead of expecting release signing config.
    sed -i 's/signingConfigs.release/signingConfigs.debug/' "${REPO_ROOT}/flutter/android/app/build.gradle"

    # Run the Flutter APK build from flutter/ with the desired ABI target.
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

  # Copy the APK into the stable output directory used by the Docker bind mount.
  mkdir -p "${output_dir}"
  [[ -f "${source_apk}" ]] || {
    printf 'ERROR: Expected APK output not found at %s\n' "${source_apk}" >&2
    return 1
  }
  cp "${source_apk}" "${output_apk}"

  log "APK available at ${output_apk}"
}

# Compose the higher-level prepare and build commands exposed by this script.
build_apk() {
  local abi="$1"

  # BUILD_MODE is read indirectly by map_abi when it constructs the expected APK filename.
  BUILD_MODE="${2:-${DEFAULT_BUILD_MODE}}"
  map_abi "${abi}"

  # Run the native dependency build, Rust build, JNI staging, Flutter packaging, and final copy in order.
  run_step "Install Android native dependencies for ${abi}" build_android_deps_step "${abi}"
  run_step "Build Rust library for ${abi}" build_rust_library_step
  run_step "Prepare JNI libraries for ${abi}" prepare_jni_libs
  run_step "Build Flutter APK for ${abi} (${BUILD_MODE})" flutter_build_apk_step
  run_step "Collect APK output for ${abi}" collect_apk_output_step
}

prepare_workspace() {
  # This is the shared setup used by both the standalone prepare command and build-apk.
  run_step "Validate repository layout" ensure_repo_root
  run_step "Validate Android build tooling" ensure_tooling
  run_step "Write Android local.properties" write_local_properties
  run_step "Ensure bridge files exist" ensure_bridge_files
  run_step "Resolve Flutter packages" ensure_flutter_packages
}

# Dispatch the requested subcommand.
main() {
  local command="${1:-}"
  local abi build_mode

  # Subcommands expose the same phases used by CI and by the Docker entrypoint.
  case "${command}" in
    prepare)
      # Validate the repo and warm up generated/package state without building an APK.
      prepare_workspace
      ;;
    bridge)
      # Regenerate bridge outputs explicitly without running the full APK build.
      ensure_repo_root
      ensure_tooling
      write_local_properties
      generate_bridge_files
      ;;
    build-apk)
      # Parse optional CLI args, run shared preparation, then execute the full build pipeline.
      TIMING_SUMMARY_ENABLED=1
      BUILD_TOTAL_START_MS="$(now_ms)"
      trap print_timing_summary EXIT
      abi="${2:-${DEFAULT_ABI}}"
      build_mode="${3:-${DEFAULT_BUILD_MODE}}"
      time_block "prepare_workspace" prepare_workspace
      time_block "build_apk" build_apk "${abi}" "${build_mode}"
      ;;
    ""|-h|--help|help)
      # No subcommand means usage, not an implicit build.
      usage
      ;;
    *)
      # Unknown subcommands print usage first for faster diagnosis.
      usage
      fail "Unknown command: ${command}"
      ;;
  esac
}

# Pass the original CLI arguments through untouched.
main "$@"
