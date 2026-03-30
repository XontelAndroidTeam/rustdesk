# Android Debug Build Plan For WSL

## Purpose

This document captures the agreed plan for building and running the Android
RustDesk client in WSL without relying on:

- `flutter/Dockerfile.android`
- `flutter/docker/android-build.sh`

The goal is to create a new WSL-first script for local debug builds, then use
that proven flow later as the basis for a new Docker image.

For the separate one-time toolchain/bootstrap plan, see
`doc/android-toolchain-bootstrap-plan-wsl.md`.

Assumed host:

- Ubuntu 24.04 LTS on WSL 2

## Decisions Already Made

### 1. Reuse Existing Repo Scripts Where They Already Encode Real Build Logic

The new WSL script should be a thin wrapper around existing project helpers,
not a replacement for them.

Scripts to reuse directly:

- `flutter/build_android_deps.sh`
- `flutter/ndk_arm64.sh`
- `flutter/ndk_arm.sh`
- `flutter/ndk_x64.sh`
- `flutter/ndk_x86.sh`

Commands and workflow logic to reuse:

- bridge generation command from `flutter/run.sh`
- bridge-generation process from `.github/workflows/bridge.yml`
- Android native packaging steps from `.github/workflows/flutter-build.yml`
- broader Android reference flow from `flutter/build_fdroid.sh`

Scripts to use only as references, not as the main debug entrypoint:

- `flutter/build_android.sh`
- `flutter/build_fdroid.sh`

Why:

- the checked-in helper scripts already contain the ABI mapping and Rust build
  choices that the repo uses
- a thin wrapper is easier to maintain than a new parallel build system
- this keeps the local flow aligned with CI

### 2. Use Linux-Native SDKs And Toolchains Inside WSL

For WSL builds, use Linux-native installs of:

- Flutter SDK
- Android SDK
- Android NDK
- Rust toolchain
- vcpkg

Recommended locations:

- `FLUTTER_HOME=$HOME/sdk/flutter`
- `ANDROID_SDK_ROOT=$HOME/Android/Sdk`
- `ANDROID_NDK_HOME=$ANDROID_SDK_ROOT/ndk/<version>`
- `VCPKG_ROOT=$HOME/sdk/vcpkg`

Why:

- the helper scripts assume Linux host layouts such as
  `toolchains/llvm/prebuilt/linux-x86_64`
- Android SDK, NDK, and Flutter binaries are host-specific
- a Linux-native toolchain in WSL matches the future Docker layout
- trying to drive Windows SDKs from WSL adds path, host-tool, and runtime
  mismatches

## Constraints To Keep In Mind

### Limited Internet Connection

The build flow should minimize repeated downloads.

That means the future WSL script should:

- avoid bootstrapping the whole machine every run
- avoid `flutter clean` by default
- avoid regenerating bridge files on every invocation
- avoid building all ABIs by default
- fail early with clear missing-tool messages instead of trying to download
  everything automatically

Recommended cache locations inside WSL:

- `PUB_CACHE=$HOME/.pub-cache`
- `GRADLE_USER_HOME=$HOME/.gradle`
- `CARGO_HOME=$HOME/.cargo`
- `CARGO_TARGET_DIR=$HOME/.cache/rustdesk-target`
- `VCPKG_DOWNLOADS=$HOME/.cache/vcpkg-downloads`

Why:

- these reduce repeated network usage
- they avoid slow build I/O on `/mnt/c`

## Source Of Truth For The Planned Flow

The plan is derived from these existing repo paths:

- `.github/workflows/bridge.yml`
- `.github/workflows/flutter-build.yml`
- `flutter/build_android_deps.sh`
- `flutter/build_fdroid.sh`
- `flutter/ndk_arm64.sh`
- `flutter/ndk_arm.sh`
- `flutter/ndk_x64.sh`
- `flutter/ndk_x86.sh`

Those files define the real bridge-generation path, Android dependency build,
Rust Android library build, and packaging into `jniLibs`.

## One-Time Setup Versus Repeatable Build Work

### One-Time Or Rare Setup

These should not happen every time the debug app is run:

1. Install Linux host tooling in WSL.
Why:
The Android and Rust build stack needs Linux packages such as Java, clang,
cmake, git, libclang, unzip, and xz support.

Planned owning script:

- `flutter/setup_android_wsl_toolchain.sh`

2. Install Linux Flutter, Rust, Android SDK/NDK, and vcpkg.
Why:
These are host toolchains, not project artifacts. They should be reused across
builds.

Planned owning script:

- `flutter/setup_android_wsl_toolchain.sh`

3. Generate bridge files if they are missing.
Files:
- `flutter/lib/generated_bridge.dart`
- `src/bridge_generated*.rs`

Why:
The checkout may not include generated bridge output, and Flutter imports the
generated Dart file directly.

4. Populate dependency caches.
Why:
The first successful build will likely download pub, Cargo, and vcpkg
dependencies. Those should be reused afterward.

Planned owning script:

- `flutter/setup_android_wsl_toolchain.sh`

### Repeatable Per-Build Work

These are the steps the future WSL script should orchestrate:

1. Verify required environment variables and tools.
Why:
Fail fast before a long build starts.

2. Rewrite `flutter/android/local.properties` with WSL paths.
Why:
The file must point at Linux SDK paths when building under WSL.

3. Run `flutter pub get` only when required.
Why:
Flutter dependencies are needed, but this should not always force network work.

4. Build Android-side native dependencies with:
`flutter/build_android_deps.sh <abi>`

Why:
This is the repo's existing helper for Android vcpkg dependencies.

5. Build the Rust shared library using the matching helper script:

- `flutter/ndk_arm64.sh`
- `flutter/ndk_arm.sh`
- `flutter/ndk_x64.sh`
- `flutter/ndk_x86.sh`

Why:
These scripts already encode the ABI-to-Rust-target mapping used by the repo.

6. Copy `liblibrustdesk.so` into:
`flutter/android/app/src/main/jniLibs/<abi>/librustdesk.so`

Why:
Android loads the packaged library under the `rustdesk` name.

7. Copy `libc++_shared.so` from the Linux NDK sysroot into the same ABI
folder.

Why:
The Android package needs that runtime library in `jniLibs`, and CI copies it
explicitly.

8. Run one of:

- `flutter run --debug --target-platform <platform>`
- `flutter build apk --debug --target-platform <platform>`

Why:
One path is for the day-to-day debug loop; the other is for generating a debug
APK artifact without launching it.

## Proposed New Script

Planned file:

- `flutter/run_android_debug_wsl.sh`

Planned responsibility:

- be a thin WSL wrapper around the existing helper scripts and bridge command
- not replace the project's current CI or release scripts

Planned subcommands:

- `check`
- `bridge`
- `prepare --abi <abi>`
- `run --abi <abi> [--device <id>]`
- `build-apk --abi <abi>`

Why this structure:

- `bridge` is explicit and easy to rerun when needed
- `prepare` builds native prerequisites without launching
- `run` is the normal local debug workflow
- `build-apk` produces a debug APK artifact directly

## ABI Strategy

The script should build one ABI at a time by default.

Recommended default:

- `arm64-v8a`

Use `x86_64` only when the target is an emulator.

Why:

- one ABI reduces build time and download cost
- one ABI is enough for the normal local debug loop

Expected mapping:

- `arm64-v8a`
  - Rust target: `aarch64-linux-android`
  - Flutter target: `android-arm64`
  - helper: `flutter/ndk_arm64.sh`

- `armeabi-v7a`
  - Rust target: `armv7-linux-androideabi`
  - Flutter target: `android-arm`
  - helper: `flutter/ndk_arm.sh`

- `x86_64`
  - Rust target: `x86_64-linux-android`
  - Flutter target: `android-x64`
  - helper: `flutter/ndk_x64.sh`

- `x86`
  - Rust target: `i686-linux-android`
  - Flutter target: `android-x86`
  - helper: `flutter/ndk_x86.sh`

## Initial Build Profile Choice

Initial recommendation:

- Flutter app: `debug`
- Rust shared library: `release`

Why:

- that keeps the local flow closer to the repo helper scripts
- it reduces variables while first making the Android path work
- true Rust debug mode can be added later once the full local flow is stable

## What The Future WSL Script Should Not Do

It should not:

- bootstrap the full machine automatically
- depend on Docker
- build all ABIs by default
- call `flutter clean` by default
- regenerate bridge files every run
- use the AI-written `flutter/Dockerfile.android` path as the source of truth

## Future Docker Direction

After the WSL script is working, that same flow should become the basis for a
new Docker image that produces APK artifacts.

Why:

- Docker should package a proven local process
- it is easier to debug the build logic in WSL first
- keeping the WSL and Docker flows aligned reduces maintenance cost
