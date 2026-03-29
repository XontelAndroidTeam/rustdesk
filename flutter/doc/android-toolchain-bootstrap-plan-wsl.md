# Android Toolchain Bootstrap Plan For WSL

## Purpose

This document captures the plan for a separate WSL-first bootstrap script that
installs and configures the Linux-native SDKs and toolchains needed for Android
builds.

This script is intended to be:

- reusable for local WSL development
- reusable as the foundation of a future Docker image
- separate from the repeatable app build/run script

The key design choice is to split the workflow into two layers:

- machine/bootstrap setup
- project build/run

Why:

- the toolchain setup is expensive and should not run every build
- the project build script should stay thin and deterministic
- the same bootstrap logic can later be copied into Docker image build steps

## Relationship To The WSL Debug Build Plan

This plan complements:

- `doc/android-debug-build-plan-wsl.md`

The future script responsibilities are:

- `flutter/setup_android_wsl_toolchain.sh`
  - prepare Linux-native host tooling, SDKs, NDK, vcpkg, and caches

- `flutter/run_android_debug_wsl.sh`
  - use those prepared toolchains to build and run the Android debug app

Why split them:

- bootstrap work is one-time or rare
- app build work is frequent
- separating them reduces accidental downloads on limited internet

## Source Of Truth

The bootstrap plan should stay aligned with the versions and expectations found
in:

- `.github/workflows/flutter-build.yml`
- `.github/workflows/bridge.yml`
- `flutter/build_android_deps.sh`
- `flutter/build_fdroid.sh`

Relevant pinned values already visible in the repo:

- Flutter Android build version: `3.24.5`
- Flutter bridge-generation version: `3.22.3`
- Rust version: `1.75`
- `cargo-ndk`: `3.1.2`
- `flutter_rust_bridge_codegen`: `1.80.1`
- Android NDK: `r28c`
- vcpkg commit: `120deac3062162151622ca4860575a33844ba10b`

Why:

- the bootstrap script must install versions that match CI assumptions
- the bootstrap script should not silently drift away from the repo workflows

## Planned Script

Planned file:

- `flutter/setup_android_wsl_toolchain.sh`

Planned responsibility:

- install or verify Linux-native prerequisites in WSL
- configure environment variables and cache locations
- prepare a stable host layout for local builds
- avoid project-specific build steps such as generating APKs

It should not:

- build the app
- generate APKs
- build all RustDesk native artifacts
- rewrite project files other than optional shell env snippets

Why:

- this keeps the bootstrap layer reusable outside a single checkout
- Docker can reuse the same logic without needing the whole project build flow

## Recommended Installation Layout

Use Linux-native installs inside WSL.

Recommended base layout:

- `FLUTTER_HOME=$HOME/sdk/flutter`
- `FLUTTER_BRIDGE_HOME=$HOME/sdk/flutter-bridge`
- `ANDROID_SDK_ROOT=$HOME/Android/Sdk`
- `ANDROID_NDK_HOME=$ANDROID_SDK_ROOT/ndk/r28c`
- `VCPKG_ROOT=$HOME/sdk/vcpkg`
- `JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64`

Recommended cache layout:

- `PUB_CACHE=$HOME/.pub-cache`
- `GRADLE_USER_HOME=$HOME/.gradle`
- `CARGO_HOME=$HOME/.cargo`
- `RUSTUP_HOME=$HOME/.rustup`
- `CARGO_TARGET_DIR=$HOME/.cache/rustdesk-target`
- `VCPKG_DOWNLOADS=$HOME/.cache/vcpkg-downloads`

Why:

- Linux-native layout matches the helper scripts and future Docker layout
- separating SDK roots from caches makes reuse and cleanup easier
- keeping caches stable reduces network usage on subsequent builds

## High-Level Bootstrap Steps

### 1. Verify WSL Host Packages

The script should install or verify Linux packages such as:

- `curl`
- `git`
- `unzip`
- `xz-utils`
- `zip`
- `clang`
- `cmake`
- `ninja-build`
- `pkg-config`
- `openjdk-17-jdk-headless`
- `libclang-dev`
- `llvm-dev`
- `gcc-multilib`
- `g++-multilib`

Why:

- these are host prerequisites for Flutter, Rust, Android NDK work, Gradle, and
  bindgen/codegen
- they are also the kind of packages a Docker image would install

### 2. Install Or Verify Rust Toolchain

The script should ensure:

- Rust `1.75`
- `cargo`
- `rustup`
- `cargo-ndk` `3.1.2`
- `cargo-expand` `1.0.95`
- `flutter_rust_bridge_codegen` `1.80.1`

Why:

- Rust is needed both for the app library and bridge generation
- `cargo-ndk` is needed for Android targets
- bridge generation depends on the same codegen tools used by CI

### 3. Install Or Verify Flutter SDKs

The script should support two Flutter installations:

- normal app-build Flutter: `3.24.5`
- bridge-generation Flutter: `3.22.3`

Why:

- the repo CI uses a dedicated Flutter version for bridge generation
- keeping them separate avoids mutating one install back and forth
- this is simpler to reproduce in Docker later

### 4. Install Or Verify Android SDK Command-Line Tools

The script should prepare:

- Android command-line tools
- platform-tools
- Android platform `34`
- Android build-tools `34.0.0`

Why:

- Flutter/Gradle need them for Android builds
- this mirrors the Docker and CI expectations

### 5. Install Or Verify Android NDK

The script should install or verify:

- NDK `r28c`

Why:

- the repo CI uses `r28c`
- the checked-in helper scripts assume Linux NDK host layout

### 6. Install Or Verify vcpkg

The script should:

- clone or reuse `vcpkg`
- check out commit `120deac3062162151622ca4860575a33844ba10b`
- bootstrap vcpkg

Why:

- Android native dependency builds depend on vcpkg
- this version should match the repo workflow expectations

### 7. Prepare Shell Environment

The script should be able to write or print an env snippet that exports:

- `FLUTTER_HOME`
- `FLUTTER_BRIDGE_HOME`
- `ANDROID_SDK_ROOT`
- `ANDROID_HOME`
- `ANDROID_NDK_HOME`
- `ANDROID_NDK_ROOT`
- `VCPKG_ROOT`
- `JAVA_HOME`
- cache variables such as `PUB_CACHE` and `GRADLE_USER_HOME`

Why:

- the build script should not need to rediscover these every time
- Docker can also reuse the same env layout

### 8. Verify Final Toolchain Health

The bootstrap script should finish with a check step that prints:

- Flutter version(s)
- Rust version
- Java version
- NDK path
- SDK path
- vcpkg path
- availability of `cargo-ndk` and `flutter_rust_bridge_codegen`

Why:

- failures are cheaper to catch before the project build starts
- this gives a clean handoff to the app build script

## Offline And Limited-Internet Strategy

Because the connection is limited, the bootstrap script should be designed to
prefer reuse over downloading.

### Required Behavior

It should:

- detect existing installs before downloading anything
- skip reinstalling correct versions
- keep caches persistent across runs
- support rerunning safely

### Optional Behavior Worth Designing For

It should be able to use pre-downloaded archives when supplied, for example:

- Flutter tarballs
- Android command-line tools zip
- Android NDK zip

Why:

- this allows one machine or one network session to fetch archives once and
  reuse them later
- the same approach fits Docker build contexts and local WSL setup

## Planned Command Shape

Recommended subcommands:

- `check`
- `install-host`
- `install-rust`
- `install-flutter`
- `install-android-sdk`
- `install-ndk`
- `install-vcpkg`
- `env`
- `all`

Why:

- partial steps are easier to debug on limited internet
- `all` gives a full bootstrap path
- `check` and `env` make the script reusable in Docker and local shells

## Idempotency Requirements

The script should be safe to rerun.

That means:

- do not redownload if the target version already exists
- do not reclone vcpkg if the correct checkout is already present
- do not overwrite caches destructively
- do not force reinstall Flutter if the expected version is already available

Why:

- repeated runs are expected during setup and debugging
- idempotency is especially important when bandwidth is constrained

## Docker Reuse Strategy

The bootstrap script should be written so Docker can call the same logic during
image build.

That means:

- avoid WSL-only assumptions except where clearly isolated
- keep paths configurable through environment variables
- separate host package install from project build
- keep all version pins explicit

Why:

- this reduces duplication between WSL and Docker
- it makes the Docker image a packaging of the known-good WSL setup path

## What The Bootstrap Script Should Not Cover

This script should not:

- generate bridge files for a specific checkout
- run `flutter pub get` for the project
- build Android vcpkg dependencies for RustDesk
- build `librustdesk.so`
- create `jniLibs`
- launch `flutter run`

Those belong to the project-level build script.

## Expected Next Step

After this bootstrap script plan is accepted, the next implementation steps are:

1. create `flutter/setup_android_wsl_toolchain.sh`
2. keep it focused on host setup only
3. then create `flutter/run_android_debug_wsl.sh` as the project build wrapper
