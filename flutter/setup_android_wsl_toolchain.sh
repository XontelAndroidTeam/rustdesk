#!/usr/bin/env bash

# Host bootstrap for RustDesk Android builds on WSL.
# Assumes Ubuntu 24.04 LTS on WSL 2 unless overridden.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

FLUTTER_VERSION="${FLUTTER_VERSION:-3.24.5}"
FLUTTER_BRIDGE_VERSION="${FLUTTER_BRIDGE_VERSION:-3.22.3}"
RUST_VERSION="${RUST_VERSION:-1.75}"
CARGO_NDK_VERSION="${CARGO_NDK_VERSION:-3.1.2}"
CARGO_EXPAND_VERSION="${CARGO_EXPAND_VERSION:-1.0.95}"
FLUTTER_RUST_BRIDGE_VERSION="${FLUTTER_RUST_BRIDGE_VERSION:-1.80.1}"
ANDROID_CMDLINE_TOOLS_VERSION="${ANDROID_CMDLINE_TOOLS_VERSION:-11076708}"
ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-34}"
ANDROID_BUILD_TOOLS_VERSION="${ANDROID_BUILD_TOOLS_VERSION:-34.0.0}"
ANDROID_NDK_RELEASE="${ANDROID_NDK_RELEASE:-r28c}"
VCPKG_COMMIT_ID="${VCPKG_COMMIT_ID:-120deac3062162151622ca4860575a33844ba10b}"

FLUTTER_HOME="${FLUTTER_HOME:-$HOME/sdk/flutter}"
FLUTTER_BRIDGE_HOME="${FLUTTER_BRIDGE_HOME:-$HOME/sdk/flutter-bridge}"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
ANDROID_HOME="${ANDROID_HOME:-$ANDROID_SDK_ROOT}"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_RELEASE}"
ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-$ANDROID_NDK_HOME}"
VCPKG_ROOT="${VCPKG_ROOT:-$HOME/sdk/vcpkg}"
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"

PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"
GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/rustdesk-target}"
VCPKG_DOWNLOADS="${VCPKG_DOWNLOADS:-$HOME/.cache/vcpkg-downloads}"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-$HOME/.cache/rustdesk-bootstrap-downloads}"

FLUTTER_MAIN_ARCHIVE="${FLUTTER_MAIN_ARCHIVE:-}"
FLUTTER_BRIDGE_ARCHIVE="${FLUTTER_BRIDGE_ARCHIVE:-}"
ANDROID_CMDLINE_TOOLS_ARCHIVE="${ANDROID_CMDLINE_TOOLS_ARCHIVE:-}"
ANDROID_NDK_ARCHIVE="${ANDROID_NDK_ARCHIVE:-}"
RUSTUP_INIT_SCRIPT="${RUSTUP_INIT_SCRIPT:-}"

FLUTTER_PATCH_PATH="${FLUTTER_PATCH_PATH:-$REPO_ROOT/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff}"
FLUTTER_PRECACHE_ANDROID="${FLUTTER_PRECACHE_ANDROID:-1}"
VERBOSE="${VERBOSE:-0}"

export FLUTTER_HOME
export FLUTTER_BRIDGE_HOME
export ANDROID_SDK_ROOT
export ANDROID_HOME
export ANDROID_NDK_HOME
export ANDROID_NDK_ROOT
export VCPKG_ROOT
export JAVA_HOME
export PUB_CACHE
export GRADLE_USER_HOME
export CARGO_HOME
export RUSTUP_HOME
export CARGO_TARGET_DIR
export VCPKG_DOWNLOADS
export PATH="$JAVA_HOME/bin:$CARGO_HOME/bin:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$FLUTTER_HOME/bin:$FLUTTER_BRIDGE_HOME/bin:$PATH"

HOST_PACKAGES=(
  ca-certificates
  clang
  cmake
  curl
  g++
  g++-multilib
  gcc-multilib
  git
  libasound2-dev
  libayatana-appindicator3-dev
  libc6-dev
  libclang-dev
  libgstreamer-plugins-base1.0-dev
  libgstreamer1.0-dev
  libgtk-3-dev
  libpam0g-dev
  libpulse-dev
  libunwind-dev
  libva-dev
  libxcb-randr0-dev
  libxcb-shape0-dev
  libxcb-xfixes0-dev
  libxdo-dev
  libxfixes-dev
  llvm-dev
  nasm
  ninja-build
  openjdk-17-jdk-headless
  pkg-config
  tree
  unzip
  wget
  xz-utils
  zip
)

usage() {
  cat <<'EOF'
Usage:
  ./flutter/setup_android_wsl_toolchain.sh [--verbose] <command>

Assumption:
  Ubuntu 24.04 LTS on WSL 2

Options:
  -v, --verbose  enable shell tracing and extra debug logs

Commands:
  check
  install-host
  install-rust
  install-flutter
  install-android-sdk
  install-ndk
  install-vcpkg
  env
  all

Environment overrides:
  FLUTTER_HOME
  FLUTTER_BRIDGE_HOME
  ANDROID_SDK_ROOT
  ANDROID_NDK_HOME
  VCPKG_ROOT
  JAVA_HOME
  DOWNLOADS_DIR
  FLUTTER_MAIN_ARCHIVE
  FLUTTER_BRIDGE_ARCHIVE
  ANDROID_CMDLINE_TOOLS_ARCHIVE
  ANDROID_NDK_ARCHIVE
  RUSTUP_INIT_SCRIPT
  VERBOSE
EOF
}

log() {
  printf '\n==> %s\n' "$*" >&2
}

is_truthy() {
  case "${1,,}" in
    1|true|yes|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

debug() {
  if is_truthy "$VERBOSE"; then
    printf '[debug] %s\n' "$*" >&2
  fi
}

enable_verbose_logging() {
  export PS4='+ ${BASH_SOURCE##*/}:${LINENO}: '
  set -x
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_dirs() {
  debug "Ensuring tool and cache directories exist"
  mkdir -p \
    "$HOME/sdk" \
    "$HOME/Android" \
    "$PUB_CACHE" \
    "$GRADLE_USER_HOME" \
    "$CARGO_HOME" \
    "$RUSTUP_HOME" \
    "$CARGO_TARGET_DIR" \
    "$VCPKG_DOWNLOADS" \
    "$DOWNLOADS_DIR"
}

require_repo_file() {
  local path="$1"
  [[ -e "$path" ]] || fail "Missing expected repo file: $path"
}

download_with_cache() {
  local url="$1"
  local cache_name="$2"
  local explicit_archive="${3:-}"
  local archive_path

  mkdir -p "$DOWNLOADS_DIR"

  if [[ -n "$explicit_archive" ]]; then
    [[ -f "$explicit_archive" ]] || fail "Archive override not found: $explicit_archive"
    debug "Using explicit archive override for $cache_name: $explicit_archive"
    printf '%s\n' "$explicit_archive"
    return
  fi

  archive_path="$DOWNLOADS_DIR/$cache_name"
  if [[ ! -f "$archive_path" ]]; then
    log "Downloading $cache_name"
    curl -fL --retry 3 --output "$archive_path" "$url"
  else
    debug "Reusing cached download for $cache_name at $archive_path"
  fi
  printf '%s\n' "$archive_path"
}

current_flutter_version() {
  local sdk_dir="$1"
  if [[ -f "$sdk_dir/version" ]]; then
    tr -d '\r\n' < "$sdk_dir/version"
    return
  fi
  if [[ -x "$sdk_dir/bin/flutter" ]]; then
    "$sdk_dir/bin/flutter" --version 2>/dev/null | awk '/Flutter / {print $2; exit}'
    return
  fi
  return 1
}

flutter_android_cache_ready() {
  local sdk_dir="$1"
  [[ -d "$sdk_dir/bin/cache/artifacts/engine/android-arm-release" ]] && \
  [[ -d "$sdk_dir/bin/cache/artifacts/engine/android-arm64-release" ]] && \
  [[ -d "$sdk_dir/bin/cache/artifacts/engine/android-x64-release" ]] && \
  [[ -d "$sdk_dir/bin/cache/artifacts/engine/android-x86-release" ]]
}

flutter_patch_equivalent_fix_present() {
  local sdk_dir="$1"
  local dropdown_menu_path="$sdk_dir/packages/flutter/lib/src/material/dropdown_menu.dart"

  [[ -f "$dropdown_menu_path" ]] || return 1

  grep -Fq 'bool _enableFilter = false;' "$dropdown_menu_path" && \
  grep -Fq 'if (oldWidget.enableFilter != widget.enableFilter) {' "$dropdown_menu_path" && \
  grep -Fq 'filteredEntries = widget.dropdownMenuEntries;' "$dropdown_menu_path"
}

patch_flutter_if_needed() {
  local sdk_dir="$1"
  local version="$2"

  [[ -f "$FLUTTER_PATCH_PATH" ]] || return
  if [[ "$version" != "3.24.4" ]]; then
    return
  fi

  if git apply --check --reverse --directory="$sdk_dir" "$FLUTTER_PATCH_PATH" >/dev/null 2>&1; then
    return
  fi

  if git apply --check --directory="$sdk_dir" "$FLUTTER_PATCH_PATH" >/dev/null 2>&1; then
    log "Applying Flutter patch for $version"
    git apply --directory="$sdk_dir" "$FLUTTER_PATCH_PATH"
  elif flutter_patch_equivalent_fix_present "$sdk_dir"; then
    log "Skipping Flutter patch for $version because the equivalent fix is already present"
  else
    fail "Flutter patch does not apply cleanly to $sdk_dir"
  fi
}

install_flutter_sdk() {
  local version="$1"
  local sdk_dir="$2"
  local archive_override="${3:-}"
  local precache_android="${4:-0}"
  local installed_version archive_path temp_dir unpack_root

  installed_version="$(current_flutter_version "$sdk_dir" || true)"
  debug "Detected Flutter SDK version at $sdk_dir: ${installed_version:-missing}"
  if [[ "$installed_version" == "$version" && -x "$sdk_dir/bin/flutter" ]]; then
    patch_flutter_if_needed "$sdk_dir" "$version"
    "$sdk_dir/bin/flutter" config --no-analytics >/dev/null
    if [[ "$precache_android" == "1" ]] && ! flutter_android_cache_ready "$sdk_dir"; then
      "$sdk_dir/bin/flutter" precache --android
    fi
    return
  fi

  archive_path="$(download_with_cache \
    "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${version}-stable.tar.xz" \
    "flutter_linux_${version}-stable.tar.xz" \
    "$archive_override")"

  temp_dir="$(mktemp -d)"
  unpack_root="$temp_dir/unpack"
  mkdir -p "$unpack_root"
  tar -xJf "$archive_path" -C "$unpack_root"

  rm -rf "$sdk_dir"
  mkdir -p "$(dirname "$sdk_dir")"
  mv "$unpack_root/flutter" "$sdk_dir"

  patch_flutter_if_needed "$sdk_dir" "$version"
  "$sdk_dir/bin/flutter" config --no-analytics >/dev/null
  if [[ "$precache_android" == "1" ]]; then
    "$sdk_dir/bin/flutter" precache --android
  fi

  rm -rf "$temp_dir"
}

sdkmanager_path() {
  printf '%s\n' "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"
}

ensure_sdkmanager() {
  local sdkmanager archive_path temp_dir extract_root nested_dir

  sdkmanager="$(sdkmanager_path)"
  if [[ -x "$sdkmanager" ]]; then
    debug "Android sdkmanager already present at $sdkmanager"
    return
  fi

  archive_path="$(download_with_cache \
    "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_VERSION}_latest.zip" \
    "commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_VERSION}_latest.zip" \
    "$ANDROID_CMDLINE_TOOLS_ARCHIVE")"

  log "Installing Android command-line tools"
  temp_dir="$(mktemp -d)"
  extract_root="$temp_dir/extract"
  mkdir -p "$extract_root" "$ANDROID_SDK_ROOT/cmdline-tools"
  unzip -q "$archive_path" -d "$extract_root"

  nested_dir="$extract_root/cmdline-tools"
  [[ -d "$nested_dir" ]] || fail "Unexpected Android command-line tools archive layout"

  rm -rf "$ANDROID_SDK_ROOT/cmdline-tools/latest"
  mv "$nested_dir" "$ANDROID_SDK_ROOT/cmdline-tools/latest"
  mkdir -p "$HOME/.android"
  : > "$HOME/.android/repositories.cfg"

  rm -rf "$temp_dir"
}

ensure_android_sdk_packages() {
  local sdkmanager

  ensure_sdkmanager
  sdkmanager="$(sdkmanager_path)"

  if [[ -d "$ANDROID_SDK_ROOT/platform-tools" ]] && \
     [[ -d "$ANDROID_SDK_ROOT/platforms/android-$ANDROID_API_LEVEL" ]] && \
     [[ -d "$ANDROID_SDK_ROOT/build-tools/$ANDROID_BUILD_TOOLS_VERSION" ]]; then
    debug "Android SDK packages already present under $ANDROID_SDK_ROOT"
    return
  fi

  log "Installing Android SDK packages"
  yes | "$sdkmanager" --licenses >/dev/null
  "$sdkmanager" \
    "platform-tools" \
    "platforms;android-${ANDROID_API_LEVEL}" \
    "build-tools;${ANDROID_BUILD_TOOLS_VERSION}"
}

ensure_android_ndk() {
  local archive_path temp_dir extract_root extracted_dir

  if [[ -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" ]]; then
    debug "Android NDK already present at $ANDROID_NDK_HOME"
    return
  fi

  archive_path="$(download_with_cache \
    "https://dl.google.com/android/repository/android-ndk-${ANDROID_NDK_RELEASE}-linux.zip" \
    "android-ndk-${ANDROID_NDK_RELEASE}-linux.zip" \
    "$ANDROID_NDK_ARCHIVE")"

  log "Installing Android NDK $ANDROID_NDK_RELEASE"
  temp_dir="$(mktemp -d)"
  extract_root="$temp_dir/extract"
  mkdir -p "$extract_root" "$(dirname "$ANDROID_NDK_HOME")"
  unzip -q "$archive_path" -d "$(dirname "$ANDROID_NDK_HOME")"

  extracted_dir="$(dirname "$ANDROID_NDK_HOME")/android-ndk-${ANDROID_NDK_RELEASE}"
  [[ -d "$extracted_dir" ]] || fail "Unexpected Android NDK archive layout"

  rm -rf "$ANDROID_NDK_HOME"
  mv "$extracted_dir" "$ANDROID_NDK_HOME"
  rm -rf "$temp_dir"
}

ensure_rust_toolchain() {
  local rustup_script cargo_cmd rustup_bin

  if ! command_exists rustup; then
    rustup_script="$(download_with_cache \
      "https://sh.rustup.rs" \
      "rustup-init.sh" \
      "$RUSTUP_INIT_SCRIPT")"
    log "Installing rustup and Rust $RUST_VERSION"
    sh "$rustup_script" -y --profile minimal --default-toolchain "$RUST_VERSION"
  else
    debug "rustup already available"
  fi

  rustup_bin="${CARGO_HOME}/bin/rustup"
  [[ -x "$rustup_bin" ]] || rustup_bin="$(command -v rustup)"
  "$rustup_bin" toolchain install "$RUST_VERSION" --profile minimal

  cargo_cmd=("${CARGO_HOME}/bin/cargo" "+${RUST_VERSION}")
  [[ -x "${cargo_cmd[0]}" ]] || cargo_cmd=("cargo" "+${RUST_VERSION}")

  if ! "${cargo_cmd[@]}" install --list | grep -q "^cargo-ndk v${CARGO_NDK_VERSION}:"; then
    log "Installing cargo-ndk $CARGO_NDK_VERSION"
    "${cargo_cmd[@]}" install cargo-ndk --version "$CARGO_NDK_VERSION" --locked
  fi

  if ! "${cargo_cmd[@]}" install --list | grep -q "^cargo-expand v${CARGO_EXPAND_VERSION}:"; then
    log "Installing cargo-expand $CARGO_EXPAND_VERSION"
    "${cargo_cmd[@]}" install cargo-expand --version "$CARGO_EXPAND_VERSION" --locked
  fi

  if ! "${cargo_cmd[@]}" install --list | grep -q "^flutter_rust_bridge_codegen v${FLUTTER_RUST_BRIDGE_VERSION}:"; then
    log "Installing flutter_rust_bridge_codegen $FLUTTER_RUST_BRIDGE_VERSION"
    "${cargo_cmd[@]}" install flutter_rust_bridge_codegen --version "$FLUTTER_RUST_BRIDGE_VERSION" --features uuid --locked
  fi
}

ensure_vcpkg() {
  local current_commit

  export VCPKG_DISABLE_METRICS=1

  if [[ ! -d "$VCPKG_ROOT/.git" ]]; then
    log "Cloning vcpkg"
    mkdir -p "$(dirname "$VCPKG_ROOT")"
    git clone https://github.com/microsoft/vcpkg "$VCPKG_ROOT"
  fi

  current_commit="$(git -C "$VCPKG_ROOT" rev-parse HEAD)"
  debug "Current vcpkg commit: $current_commit"
  if [[ "$current_commit" != "$VCPKG_COMMIT_ID" ]]; then
    log "Checking out vcpkg commit $VCPKG_COMMIT_ID"
    if git -C "$VCPKG_ROOT" cat-file -e "$VCPKG_COMMIT_ID^{commit}" 2>/dev/null; then
      git -C "$VCPKG_ROOT" checkout "$VCPKG_COMMIT_ID"
    else
      git -C "$VCPKG_ROOT" fetch --depth 1 origin "$VCPKG_COMMIT_ID"
      git -C "$VCPKG_ROOT" checkout "$VCPKG_COMMIT_ID"
    fi
  fi

  if [[ ! -x "$VCPKG_ROOT/vcpkg" ]]; then
    log "Bootstrapping vcpkg"
    (cd "$VCPKG_ROOT" && ./bootstrap-vcpkg.sh -disableMetrics)
  fi
}

install_host() {
  command_exists apt-get || fail "install-host currently supports apt-based distributions only"
  log "Installing host packages"
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get update
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${HOST_PACKAGES[@]}"
}

install_rust() {
  ensure_dirs
  ensure_rust_toolchain
}

install_flutter() {
  ensure_dirs
  log "Installing Flutter $FLUTTER_VERSION"
  install_flutter_sdk "$FLUTTER_VERSION" "$FLUTTER_HOME" "$FLUTTER_MAIN_ARCHIVE" "$FLUTTER_PRECACHE_ANDROID"
  log "Installing bridge Flutter $FLUTTER_BRIDGE_VERSION"
  install_flutter_sdk "$FLUTTER_BRIDGE_VERSION" "$FLUTTER_BRIDGE_HOME" "$FLUTTER_BRIDGE_ARCHIVE" 0
}

install_android_sdk() {
  ensure_dirs
  ensure_sdkmanager
  ensure_android_sdk_packages
}

install_ndk() {
  ensure_dirs
  ensure_android_ndk
}

install_vcpkg_cmd() {
  ensure_dirs
  ensure_vcpkg
}

print_env() {
  cat <<EOF
export FLUTTER_HOME="$FLUTTER_HOME"
export FLUTTER_BRIDGE_HOME="$FLUTTER_BRIDGE_HOME"
export ANDROID_SDK_ROOT="$ANDROID_SDK_ROOT"
export ANDROID_HOME="$ANDROID_HOME"
export ANDROID_NDK_HOME="$ANDROID_NDK_HOME"
export ANDROID_NDK_ROOT="$ANDROID_NDK_ROOT"
export VCPKG_ROOT="$VCPKG_ROOT"
export JAVA_HOME="$JAVA_HOME"
export PUB_CACHE="$PUB_CACHE"
export GRADLE_USER_HOME="$GRADLE_USER_HOME"
export CARGO_HOME="$CARGO_HOME"
export RUSTUP_HOME="$RUSTUP_HOME"
export CARGO_TARGET_DIR="$CARGO_TARGET_DIR"
export VCPKG_DOWNLOADS="$VCPKG_DOWNLOADS"
export PATH="$JAVA_HOME/bin:$CARGO_HOME/bin:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$FLUTTER_HOME/bin:$FLUTTER_BRIDGE_HOME/bin:\$PATH"
EOF
}

check_command() {
  local label="$1"
  local command_name="$2"
  if command_exists "$command_name"; then
    printf '[ok] %s: %s\n' "$label" "$(command -v "$command_name")"
  else
    fail "Missing command: $command_name"
  fi
}

check_path() {
  local label="$1"
  local path="$2"
  if [[ -e "$path" ]]; then
    printf '[ok] %s: %s\n' "$label" "$path"
  else
    fail "Missing path for $label: $path"
  fi
}

check_versions() {
  local flutter_version_actual bridge_version_actual rustc_version java_version sdkmanager_bin vcpkg_bin

  flutter_version_actual="$(current_flutter_version "$FLUTTER_HOME" || true)"
  [[ "$flutter_version_actual" == "$FLUTTER_VERSION" ]] || fail "Flutter version mismatch: expected $FLUTTER_VERSION, got ${flutter_version_actual:-missing}"

  bridge_version_actual="$(current_flutter_version "$FLUTTER_BRIDGE_HOME" || true)"
  [[ "$bridge_version_actual" == "$FLUTTER_BRIDGE_VERSION" ]] || fail "Bridge Flutter version mismatch: expected $FLUTTER_BRIDGE_VERSION, got ${bridge_version_actual:-missing}"

  rustc_version="$(rustup run "$RUST_VERSION" rustc --version 2>/dev/null || true)"
  [[ -n "$rustc_version" ]] || fail "Rust toolchain $RUST_VERSION is not available"

  java_version="$("$JAVA_HOME/bin/java" -version 2>&1 | head -n 1 || true)"
  [[ -n "$java_version" ]] || fail "Java is not available at $JAVA_HOME"

  sdkmanager_bin="$(sdkmanager_path)"
  [[ -x "$sdkmanager_bin" ]] || fail "sdkmanager not found at $sdkmanager_bin"

  vcpkg_bin="$VCPKG_ROOT/vcpkg"
  [[ -x "$vcpkg_bin" ]] || fail "vcpkg binary not found at $vcpkg_bin"

  if ! cargo +"$RUST_VERSION" install --list | grep -q "^cargo-ndk v${CARGO_NDK_VERSION}:"; then
    fail "cargo-ndk $CARGO_NDK_VERSION is not installed for Rust $RUST_VERSION"
  fi

  if ! cargo +"$RUST_VERSION" install --list | grep -q "^flutter_rust_bridge_codegen v${FLUTTER_RUST_BRIDGE_VERSION}:"; then
    fail "flutter_rust_bridge_codegen $FLUTTER_RUST_BRIDGE_VERSION is not installed for Rust $RUST_VERSION"
  fi

  printf '[ok] Flutter: %s\n' "$flutter_version_actual"
  printf '[ok] Bridge Flutter: %s\n' "$bridge_version_actual"
  printf '[ok] Rust: %s\n' "$rustc_version"
  printf '[ok] Java: %s\n' "$java_version"
}

check_all() {
  ensure_dirs
  check_path "Repo root" "$REPO_ROOT"
  check_path "Flutter SDK" "$FLUTTER_HOME/bin/flutter"
  check_path "Bridge Flutter SDK" "$FLUTTER_BRIDGE_HOME/bin/flutter"
  check_path "Android SDK root" "$ANDROID_SDK_ROOT"
  check_path "Android NDK root" "$ANDROID_NDK_HOME"
  check_path "vcpkg root" "$VCPKG_ROOT"
  check_command "curl" curl
  check_command "git" git
  check_command "cargo" cargo
  check_command "rustup" rustup
  check_command "flutter" flutter
  check_versions
}

install_all() {
  install_host
  install_rust
  install_flutter
  install_android_sdk
  install_ndk
  install_vcpkg_cmd
  check_all
}

main() {
  local command

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--verbose)
        VERBOSE=1
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  if is_truthy "$VERBOSE"; then
    enable_verbose_logging
    debug "Verbose logging enabled"
    debug "Repo root: $REPO_ROOT"
    debug "Downloads directory: $DOWNLOADS_DIR"
  fi

  command="${1:-}"

  case "$command" in
    check)
      check_all
      ;;
    install-host)
      install_host
      ;;
    install-rust)
      install_rust
      ;;
    install-flutter)
      install_flutter
      ;;
    install-android-sdk)
      install_android_sdk
      ;;
    install-ndk)
      install_ndk
      ;;
    install-vcpkg)
      install_vcpkg_cmd
      ;;
    env)
      print_env
      ;;
    all)
      install_all
      ;;
    ""|-h|--help|help)
      usage
      ;;
    *)
      usage
      fail "Unknown command: $command"
      ;;
  esac
}

main "$@"
