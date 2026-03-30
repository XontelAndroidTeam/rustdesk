#!/usr/bin/env bash

set -euo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
ANDROID_OUTPUT_DIR="${ANDROID_OUTPUT_DIR:-${WORKSPACE}/out/android}"
ANDROID_ABIS="${ANDROID_ABIS:-arm64-v8a}"
ANDROID_BUILD_MODE="${ANDROID_BUILD_MODE:-release}"
ANDROID_SPLIT_PER_ABI="${ANDROID_SPLIT_PER_ABI:-1}"
ANDROID_ARTIFACT="${ANDROID_ARTIFACT:-apk}"
GENERATE_BRIDGE="${GENERATE_BRIDGE:-auto}"
FLUTTER_BUILD_VERSION="${FLUTTER_BUILD_VERSION:-3.24.5}"
FLUTTER_BRIDGE_VERSION="${FLUTTER_BRIDGE_VERSION:-3.22.3}"
BRIDGE_FLUTTER_DIR="${BRIDGE_FLUTTER_DIR:-/opt/flutter-bridge}"
FLUTTER_PATCH_PATH="${WORKSPACE}/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff"

export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
export PATH="${JAVA_HOME}/bin:${FLUTTER_HOME:-/opt/flutter}/bin:${ANDROID_SDK_ROOT:-/opt/android-sdk}/cmdline-tools/latest/bin:${ANDROID_SDK_ROOT:-/opt/android-sdk}/platform-tools:${CARGO_HOME:-/root/.cargo}/bin:${PATH}"
export VCPKG_ROOT="${VCPKG_ROOT:-/opt/vcpkg}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT}}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${ANDROID_SDK_ROOT}/ndk/${ANDROID_NDK_RELEASE:-r28c}}"
export ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME}}"
export FLUTTER_HOME="${FLUTTER_HOME:-/opt/flutter}"

if command -v llvm-config >/dev/null 2>&1; then
  export LIBCLANG_PATH="${LIBCLANG_PATH:-$(llvm-config --libdir)}"
fi

TMP_DIR="$(mktemp -d)"
declare -a BACKUPS=()

cleanup() {
  local entry file backup
  for entry in "${BACKUPS[@]}"; do
    file="${entry%%:*}"
    backup="${entry#*:}"
    if [ -n "${backup}" ] && [ -f "${backup}" ]; then
      cp "${backup}" "${file}"
    else
      rm -f "${file}"
    fi
  done
  rm -rf "${TMP_DIR}"
}

trap cleanup EXIT

backup_file() {
  local file="$1"
  local backup="${TMP_DIR}/$(printf '%03d' "${#BACKUPS[@]}")"
  if [ -f "${file}" ]; then
    cp "${file}" "${backup}"
    BACKUPS+=("${file}:${backup}")
  else
    BACKUPS+=("${file}:")
  fi
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

prepare_flutter_sdk() {
  local version="$1"
  local sdk_dir="$2"
  local archive
  local unpack_root

  if [ -x "${sdk_dir}/bin/flutter" ]; then
    return
  fi

  archive="${TMP_DIR}/flutter-${version}.tar.xz"
  unpack_root="${TMP_DIR}/flutter-sdk-${version}"
  log "Downloading Flutter ${version} into ${sdk_dir}"
  mkdir -p "$(dirname "${sdk_dir}")"
  rm -rf "${unpack_root}" "${sdk_dir}"
  curl -fsSL -o "${archive}" "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${version}-stable.tar.xz"
  mkdir -p "${unpack_root}"
  tar -xJf "${archive}" -C "${unpack_root}"
  mv "${unpack_root}/flutter" "${sdk_dir}"
  PATH="${sdk_dir}/bin:${PATH}" flutter config --no-analytics >/dev/null
}

patch_flutter_sdk_if_needed() {
  local sdk_dir="$1"
  local version="$2"

  if [ ! -f "${FLUTTER_PATCH_PATH}" ]; then
    return
  fi

  if ! dpkg --compare-versions "${version}" ge "3.24.4"; then
    return
  fi

  if git apply --check --reverse --directory="${sdk_dir}" "${FLUTTER_PATCH_PATH}" >/dev/null 2>&1; then
    return
  fi

  if git apply --check --directory="${sdk_dir}" "${FLUTTER_PATCH_PATH}" >/dev/null 2>&1; then
    log "Applying Flutter patch for ${version}"
    git apply --directory="${sdk_dir}" "${FLUTTER_PATCH_PATH}"
  else
    log "Skipping Flutter patch; it no longer applies cleanly to ${version}"
  fi
}

has_bridge_files() {
  [ -f "${WORKSPACE}/flutter/lib/generated_bridge.dart" ] && compgen -G "${WORKSPACE}/src/bridge_generated*.rs" >/dev/null
}

generate_bridge_if_needed() {
  local pubspec="${WORKSPACE}/flutter/pubspec.yaml"
  local lockfile="${WORKSPACE}/flutter/pubspec.lock"
  local pubspec_backup="${TMP_DIR}/bridge-pubspec.yaml"
  local lock_backup="${TMP_DIR}/bridge-pubspec.lock"

  case "${GENERATE_BRIDGE}" in
    0|false|no)
      return
      ;;
    auto)
      if has_bridge_files; then
        return
      fi
      ;;
  esac

  log "Generating flutter_rust_bridge files"
  prepare_flutter_sdk "${FLUTTER_BRIDGE_VERSION}" "${BRIDGE_FLUTTER_DIR}"
  patch_flutter_sdk_if_needed "${BRIDGE_FLUTTER_DIR}" "${FLUTTER_BRIDGE_VERSION}"

  cp "${pubspec}" "${pubspec_backup}"
  if [ -f "${lockfile}" ]; then
    cp "${lockfile}" "${lock_backup}"
  fi

  if grep -q 'extended_text: 14.0.0' "${pubspec}"; then
    sed -i 's/extended_text: 14.0.0/extended_text: 13.0.0/g' "${pubspec}"
  fi

  pushd "${WORKSPACE}/flutter" >/dev/null
  PATH="${BRIDGE_FLUTTER_DIR}/bin:${PATH}" flutter pub get
  popd >/dev/null

  flutter_rust_bridge_codegen \
    --rust-input "${WORKSPACE}/src/flutter_ffi.rs" \
    --dart-output "${WORKSPACE}/flutter/lib/generated_bridge.dart" \
    --c-output "${WORKSPACE}/flutter/macos/Runner/bridge_generated.h"

  if [ -f "${WORKSPACE}/flutter/macos/Runner/bridge_generated.h" ]; then
    cp "${WORKSPACE}/flutter/macos/Runner/bridge_generated.h" "${WORKSPACE}/flutter/ios/Runner/bridge_generated.h"
  fi

  cp "${pubspec_backup}" "${pubspec}"
  if [ -f "${lock_backup}" ]; then
    cp "${lock_backup}" "${lockfile}"
  else
    rm -f "${lockfile}"
  fi
}

configure_flutter_project() {
  local local_properties="${WORKSPACE}/flutter/android/local.properties"
  local gradle_properties="${WORKSPACE}/flutter/android/gradle.properties"
  local app_build_gradle="${WORKSPACE}/flutter/android/app/build.gradle"

  backup_file "${local_properties}"
  cat > "${local_properties}" <<EOF
sdk.dir=${ANDROID_SDK_ROOT}
flutter.sdk=${FLUTTER_HOME}
flutter.buildMode=${ANDROID_BUILD_MODE}
EOF

  backup_file "${gradle_properties}"
  if grep -q '^org.gradle.jvmargs=' "${gradle_properties}"; then
    sed -i 's/^org.gradle.jvmargs=.*/org.gradle.jvmargs=-Xmx2g/' "${gradle_properties}"
  else
    printf '\norg.gradle.jvmargs=-Xmx2g\n' >> "${gradle_properties}"
  fi

  if [ "${ANDROID_BUILD_MODE}" = "release" ] && [ ! -f "${WORKSPACE}/flutter/android/key.properties" ]; then
    backup_file "${app_build_gradle}"
    sed -i 's/signingConfigs.release/signingConfigs.debug/g' "${app_build_gradle}"
    log "No flutter/android/key.properties found; using debug signing for release build"
  fi
}

flutter_target_for_abi() {
  case "$1" in
    arm64-v8a) printf '%s' 'android-arm64' ;;
    armeabi-v7a) printf '%s' 'android-arm' ;;
    x86_64) printf '%s' 'android-x64' ;;
    x86) printf '%s' 'android-x86' ;;
    *) return 1 ;;
  esac
}

rust_target_for_abi() {
  case "$1" in
    arm64-v8a) printf '%s' 'aarch64-linux-android' ;;
    armeabi-v7a) printf '%s' 'armv7-linux-androideabi' ;;
    x86_64) printf '%s' 'x86_64-linux-android' ;;
    x86) printf '%s' 'i686-linux-android' ;;
    *) return 1 ;;
  esac
}

helper_script_for_abi() {
  case "$1" in
    arm64-v8a) printf '%s' 'ndk_arm64.sh' ;;
    armeabi-v7a) printf '%s' 'ndk_arm.sh' ;;
    x86_64) printf '%s' 'ndk_x64.sh' ;;
    x86) printf '%s' 'ndk_x86.sh' ;;
    *) return 1 ;;
  esac
}

cxx_runtime_subdir_for_abi() {
  case "$1" in
    arm64-v8a) printf '%s' 'aarch64-linux-android' ;;
    armeabi-v7a) printf '%s' 'arm-linux-androideabi' ;;
    x86_64) printf '%s' 'x86_64-linux-android' ;;
    x86) printf '%s' 'i686-linux-android' ;;
    *) return 1 ;;
  esac
}

prepare_workspace() {
  [ -d "${WORKSPACE}" ] || fail "Workspace ${WORKSPACE} does not exist"
  [ -f "${WORKSPACE}/Cargo.toml" ] || fail "Mount the repository root at ${WORKSPACE}"
  [ -d "${WORKSPACE}/flutter" ] || fail "Expected flutter/ under ${WORKSPACE}"

  git config --global --add safe.directory '*' >/dev/null 2>&1 || true

  pushd "${WORKSPACE}" >/dev/null
  if [ -e .git ] || [ -d .git ]; then
    git submodule update --init --recursive
  fi
  popd >/dev/null

  [ -d "${WORKSPACE}/libs/hbb_common" ] || fail "libs/hbb_common is missing; initialize submodules first"
}

build_native_artifacts() {
  local abi="$1"
  local rust_target helper jni_dir cxx_subdir runtime_src runtime_dest

  rust_target="$(rust_target_for_abi "${abi}")"
  helper="$(helper_script_for_abi "${abi}")"
  jni_dir="${WORKSPACE}/flutter/android/app/src/main/jniLibs/${abi}"
  cxx_subdir="$(cxx_runtime_subdir_for_abi "${abi}")"
  runtime_src="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/${cxx_subdir}/libc++_shared.so"
  runtime_dest="${jni_dir}/libc++_shared.so"

  log "Installing vcpkg Android dependencies for ${abi}"
  pushd "${WORKSPACE}" >/dev/null
  bash "./flutter/build_android_deps.sh" "${abi}"
  popd >/dev/null

  log "Building Rust library for ${abi}"
  rustup target add "${rust_target}"
  pushd "${WORKSPACE}" >/dev/null
  bash "./flutter/${helper}"
  popd >/dev/null

  mkdir -p "${jni_dir}"
  cp "${WORKSPACE}/target/${rust_target}/release/liblibrustdesk.so" "${jni_dir}/librustdesk.so"
  cp "${runtime_src}" "${runtime_dest}"
}

build_flutter_artifact() {
  local target_platforms="$1"
  local output_dir
  local -a build_cmd

  output_dir="${WORKSPACE}/flutter/build/app/outputs"

  pushd "${WORKSPACE}/flutter" >/dev/null
  flutter pub get

  if [ "${ANDROID_ARTIFACT}" = "appbundle" ]; then
    build_cmd=(flutter build appbundle "--${ANDROID_BUILD_MODE}" --target-platform "${target_platforms}")
  else
    build_cmd=(flutter build apk "--${ANDROID_BUILD_MODE}" --target-platform "${target_platforms}")
    if [ "${ANDROID_SPLIT_PER_ABI}" = "1" ]; then
      build_cmd+=(--split-per-abi)
    fi
  fi

  log "Running ${build_cmd[*]}"
  "${build_cmd[@]}"
  popd >/dev/null

  mkdir -p "${ANDROID_OUTPUT_DIR}"
  if [ "${ANDROID_ARTIFACT}" = "appbundle" ]; then
    find "${output_dir}/bundle" -type f -name '*.aab' -exec cp -f {} "${ANDROID_OUTPUT_DIR}/" \;
  else
    find "${output_dir}/flutter-apk" -maxdepth 1 -type f -name '*.apk' -exec cp -f {} "${ANDROID_OUTPUT_DIR}/" \;
  fi
}

main() {
  local abi_csv abi target target_platforms
  local -a abi_list=()
  local -a target_list=()

  case "${ANDROID_BUILD_MODE}" in
    debug|profile|release) ;;
    *) fail "ANDROID_BUILD_MODE must be one of: debug, profile, release" ;;
  esac

  case "${ANDROID_ARTIFACT}" in
    apk|appbundle) ;;
    *) fail "ANDROID_ARTIFACT must be one of: apk, appbundle" ;;
  esac

  prepare_workspace
  patch_flutter_sdk_if_needed "${FLUTTER_HOME}" "${FLUTTER_BUILD_VERSION}"
  generate_bridge_if_needed
  configure_flutter_project

  abi_csv="$(printf '%s' "${ANDROID_ABIS}" | tr ' ' ',' | tr -s ',')"
  IFS=',' read -r -a abi_list <<< "${abi_csv}"

  if [ "${#abi_list[@]}" -eq 0 ]; then
    fail "ANDROID_ABIS must not be empty"
  fi

  pushd "${WORKSPACE}" >/dev/null
  for abi in "${abi_list[@]}"; do
    abi="$(trim "${abi}")"
    [ -n "${abi}" ] || continue
    target="$(flutter_target_for_abi "${abi}")" || fail "Unsupported ABI: ${abi}"
    target_list+=("${target}")
    build_native_artifacts "${abi}"
  done
  popd >/dev/null

  target_platforms="$(IFS=,; printf '%s' "${target_list[*]}")"
  [ -n "${target_platforms}" ] || fail "No valid ABI targets were selected"
  build_flutter_artifact "${target_platforms}"

  log "Artifacts copied to ${ANDROID_OUTPUT_DIR}"
  find "${ANDROID_OUTPUT_DIR}" -maxdepth 1 -type f \( -name '*.apk' -o -name '*.aab' \) -print | sort
}

main "$@"
