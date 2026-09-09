# Flutter Build Guide

This guide is the detailed build reference for the Xontel fork of RustDesk.

If you are choosing a build path or looking for the shortest route through the
docs, start with [README.md](README.md). The primary local Android path in this
checkout is the Debian Docker workflow summarized there and expanded in
[android-docker-build-environment.md](android-docker-build-environment.md).

## Short Answer

Yes, this project needs dependencies before building. It is not a pure Flutter-only app.

## What Must Exist Before A Real Build

- the full repository root, not only the `flutter/` folder
- initialized Git submodules
- Git and network access for Git-backed Dart and Rust dependencies
- Flutter SDK
- Rust toolchain
- Android SDK and NDK for Android builds
- vcpkg and `VCPKG_ROOT`
- generated flutter-rust-bridge files
- built Rust shared libraries for Android APK packaging

## Toolchain Pins Found In This Repo

These are the versions the repository and CI currently point to:

- Flutter build version: `3.24.5`
- Flutter minimum from `pubspec.lock`: `>=3.24.0`
- Flutter version used by the bridge CI job: `3.22.3`
- Rust version for Android and bridge generation: `1.75`
- `cargo-ndk`: `3.1.2`
- `flutter_rust_bridge_codegen`: `1.80.1`
- Android NDK in CI: `r28c`
- vcpkg commit: `120deac3062162151622ca4860575a33844ba10b`
- Gradle wrapper: `7.6.4`
- Android Gradle Plugin: `7.3.1`
- `compileSdkVersion`: `34`
- `targetSdkVersion`: `33`
- `minSdkVersion`: `22`

## How The Build Pieces Fit Together

There are three different layers in this repo, and they do different jobs:

- GitHub workflows under `.github/workflows/` orchestrate CI jobs, runner selection, caches, secrets, and release uploads.
- Shell scripts under `flutter/` and `res/` hold reusable build and packaging commands.
- Dockerfiles define optional local containerized build environments. In this checkout, the only real Dockerfile is the root `Dockerfile`.

The main call graph looks like this:

```text
flutter-ci.yml / flutter-nightly.yml / flutter-tag.yml
  -> flutter-build.yml
     -> flutter/build_android_deps.sh
     -> flutter/ndk_arm64.sh, flutter/ndk_arm.sh, flutter/ndk_x64.sh, flutter/ndk_x86.sh

fdroid.yml
  -> publishes rustdesk-version.txt
external F-Droid builder
  -> flutter/build_fdroid.sh
     -> reads flutter-build.yml and bridge.yml for version pins
     -> calls flutter/build_android_deps.sh

README Docker commands
  -> Dockerfile
     -> entrypoint.sh
        -> cargo build
```

Important details:

- `flutter-ci.yml`, `flutter-nightly.yml`, and `flutter-tag.yml` are thin entrypoints that all call the reusable `flutter-build.yml` workflow.
- `bridge.yml` is a separate workflow for flutter-rust-bridge code generation. It is not folded into the Android APK workflow.
- `flutter/build_android_deps.sh` and the `flutter/ndk_*.sh` scripts are the main checked-in shell helpers used by Android CI.
- `flutter/run.sh`, `flutter/build_android.sh`, and `flutter/build_ios.sh` are local/manual helper scripts. They mirror parts of CI logic, but CI does not call them directly in this checkout.
- `flutter/build_fdroid.sh` is not run by GitHub Actions directly. It is written for the external F-Droid builder and intentionally reads `.github/workflows/flutter-build.yml` and `.github/workflows/bridge.yml` so F-Droid stays aligned with CI pins.
- `res/startwm.sh` is packaging/runtime support, not CI orchestration. `build.py` copies it into Linux packages.

## Required Setup

### 1. Clone The Full Repo And Init Submodules

`libs/hbb_common` is a submodule, and Android/Gradle also reads files from the parent repo.

```bash
git clone --recurse-submodules <repo-url>
cd rustdesk-fork
git submodule update --init --recursive
```

### 2. Install Core Tooling

Install at least:

- Flutter SDK
- Rust `1.75`
- Android SDK with command-line tools
- Android NDK `r28c` or newer
- vcpkg
- Git

For Android builds, also install:

```bash
cargo install cargo-ndk --version 3.1.2 --locked
```

For bridge generation, install:

```bash
cargo install cargo-expand --version 1.0.95 --locked
cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid --locked
```

### 3. Set Environment Variables

At minimum:

```bash
export VCPKG_ROOT=<path-to-vcpkg>
export ANDROID_SDK_ROOT=<path-to-android-sdk>
export ANDROID_NDK_HOME=<path-to-android-ndk>
export ANDROID_NDK_ROOT=<path-to-android-ndk>
```

### 4. Ensure `flutter/android/local.properties` Exists

This project expects `flutter/android/local.properties` to contain at least:

```properties
sdk.dir=<android-sdk-path>
flutter.sdk=<flutter-sdk-path>
```

The current checkout already has a local file with those keys, which confirms they are required for local builds.

### 5. Understand Android Signing Inputs

Android release signing in this repo is configured in
`flutter/android/app/build.gradle`.

What that Gradle file does:

- loads `key.properties` from the Android root at `flutter/android/key.properties`
- defines `signingConfigs.release`
- points the `release` build type at `signingConfigs.release`

Expected `key.properties` keys, copied from
`flutter/android/key.properties.example`:

```properties
storeFile=../key.jks
storePassword=YOUR_STORE_PASSWORD
keyAlias=YOUR_KEY_ALIAS
keyPassword=YOUR_KEY_PASSWORD
```

Important details:

- the keystore itself is not stored in the repo, and both files are gitignored
- the keystore belongs at the fixed path `flutter/android/key.jks`
- `storeFile` is resolved by Gradle from the app module
  (`flutter/android/app`), so the relative `../key.jks` resolves to that fixed
  path and works unchanged on the host and inside the container
- prefer that relative value over an absolute one: an absolute host path breaks
  in Docker, and an absolute `/workspace/...` path breaks on the host
- only the `release` build type consults this config, so `debug` and `profile`
  builds need neither file

## Fetch Flutter Packages

From `flutter/`:

```bash
cd flutter
flutter pub get
```

This needs Git/network on a clean machine because `pubspec.yaml` pulls several packages from GitHub.

## Bridge Generation

This checkout is currently missing:

- `flutter/lib/generated_bridge.dart`
- `src/bridge_generated*.rs`

That means a clean build needs a bridge-generation step first.

Typical local flow:

```bash
cd flutter
flutter pub get
~/.cargo/bin/flutter_rust_bridge_codegen \
  --rust-input ../src/flutter_ffi.rs \
  --dart-output ./lib/generated_bridge.dart \
  --c-output ./macos/Runner/bridge_generated.h
cp ./macos/Runner/bridge_generated.h ./ios/Runner/bridge_generated.h
```

Important note:

- the repo CI generates bridge files in a dedicated workflow, not as part of the Android APK workflow
- that bridge workflow uses Flutter `3.22.3`
- it also temporarily changes `extended_text` from `14.0.0` to `13.0.0`

If bridge generation fails with the normal app Flutter version, follow `.github/workflows/bridge.yml` exactly.

## Local Development Run

For a local development-style run, the repo already has `flutter/run.sh`:

```bash
cd flutter
bash run.sh
```

That script does the following:

- installs `flutter_rust_bridge_codegen`
- runs `flutter pub get`
- generates bridge files
- builds the Rust side with `cargo build --features flutter`
- runs `flutter run`

## Desktop Flutter Build

From the repository root, the documented desktop Flutter packaging commands are:

```bash
python3 build.py --flutter
python3 build.py --flutter --release
```

Those commands belong to the root workspace because they build both Rust and Flutter parts together.

## Android APK Build

The important detail is that `flutter build apk` alone is not enough on a clean checkout. The Rust shared library must exist first.

If you want the agreed WSL-first plan for a repeatable local debug flow, see
`doc/android-debug-build-plan-wsl.md`.

If you want the separate one-time WSL toolchain/bootstrap plan, see
`doc/android-toolchain-bootstrap-plan-wsl.md`.

If you want the reasoning and decision trail that led to those plans, see
`doc/android-build-learning-journey.md`.

If you want the device-side testing flow after the APK is installed on an
Android tablet, see `doc/android-tablet-testing-guide.md`.

### 1. Build Native Android Dependencies With vcpkg

Run this from the repository root:

```bash
bash flutter/build_android_deps.sh arm64-v8a
bash flutter/build_android_deps.sh armeabi-v7a
```

The script itself says it requires:

- `ANDROID_NDK_HOME`
- `VCPKG_ROOT`
- initialized vcpkg
- NDK `r25c` or newer

### 2. Add Rust Android Targets

```bash
rustup target add aarch64-linux-android armv7-linux-androideabi
```

### 3. Build The Rust Shared Libraries

From the repository root:

```bash
cargo ndk --platform 21 --target aarch64-linux-android --bindgen build --release --features "flutter,hwcodec"
cargo ndk --platform 21 --target armv7-linux-androideabi --bindgen build --release --features "flutter,hwcodec"
```

Equivalent helper scripts also exist:

```bash
bash flutter/ndk_arm64.sh
bash flutter/ndk_arm.sh
```

### 4. Copy The Rust Output Into `jniLibs`

From the repository root:

```bash
mkdir -p flutter/android/app/src/main/jniLibs/arm64-v8a
mkdir -p flutter/android/app/src/main/jniLibs/armeabi-v7a

cp target/aarch64-linux-android/release/liblibrustdesk.so flutter/android/app/src/main/jniLibs/arm64-v8a/librustdesk.so
cp target/armv7-linux-androideabi/release/liblibrustdesk.so flutter/android/app/src/main/jniLibs/armeabi-v7a/librustdesk.so
```

### 5. Copy `libc++_shared.so` From The NDK Sysroot

Each ABI folder also needs the matching NDK C++ runtime library.

Typical Linux-host paths:

```text
<NDK>/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so
<NDK>/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/arm-linux-androideabi/libc++_shared.so
```

Copy each file into the matching `flutter/android/app/src/main/jniLibs/<abi>/` folder.

### 6. Build The APK

From the `flutter/` directory:

```bash
cd flutter
flutter build apk --release --target-platform android-arm64,android-arm
```

Or use the checked-in helper script after `jniLibs` has already been prepared:

```bash
cd flutter
MODE=release bash build_android.sh
```

### 7. How Signing Happens

The build mode decides the key. There are two signing implementations to keep
straight: Gradle's own, used by every local and Docker build, and a separate
post-build step used only by CI.

#### Gradle signing, local and in Docker

Whether you run:

```bash
cd flutter
flutter build apk --release --target-platform android-arm64,android-arm
```

or:

```bash
./flutter/docker/run-android-container.sh --auto-prepare -- \
  rustdesk-android-build build-apk arm64-v8a release
```

Gradle uses the `release` signing config from `flutter/android/app/build.gradle`.
The Docker helper no longer rewrites that config, so both paths behave the same.

That means for a `release` build:

- `flutter/android/key.properties` must exist, and the keystore its `storeFile`
  entry names must exist too (by convention `flutter/android/key.jks`)
- the APK is signed during the normal Gradle packaging step
- the Docker helper reads `storeFile` back from `key.properties` and aborts before
  any build work if the config or the keystore it names is missing, so
  `key.properties` stays the single source of truth for where the key lives

For `debug` and `profile` builds nothing is required: no build type other than
`release` has a `signingConfig`, so AGP's default debug keystore is used.

Build output flow for `rustdesk-android-build build-apk arm64-v8a release`:

- Flutter/Gradle first writes
  `flutter/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`
- the helper then copies that APK into the stable output directory
  `signed-apk/rustdesk-<version>-arm64-v8a.apk`
- `debug` and `profile` builds are copied to `unsigned-apk/` instead
- `signed-apk/` is visible on the host through the whole-repo `/workspace` mount;
  note that `run-android-container.sh --output PATH` repoints only the
  `unsigned-apk` mount, so passing it a path outside the repo splits the two
  output directories

#### GitHub Actions and `act`

The CI workflow uses a separate post-build signing path.

What it does:

- first builds the APK after temporarily switching to `signingConfigs.debug`
- writes that artifact into `unsigned-apk/`
- if signing secrets are present, copies the APK into `signed-apk/`
- runs `r0adkll/sign-android-release` with a base64-encoded keystore and the
  alias/password secrets

This means the local Gradle signing path and the CI signing path are not the
same implementation, even though both can produce a signed APK artifact.

## Caveats That Matter

- `flutter build apk` does not build `librustdesk.so` for you
- `android/app/build.gradle` runs `cargo metadata`, so Cargo must be available during Gradle resolution
- Gradle also reads protobufs from `../libs/hbb_common/protos`, so the parent repo layout matters
- the helper Android scripts are Linux-first in several places and hardcode `linux-x86_64` NDK host paths
- on Windows, the most reproducible route is WSL/Linux or adapting those host-tag paths manually

## Bottom Line

If the question is "can I just open `flutter/` and run `flutter build apk`?", the answer is no for a clean checkout.

You need:

- submodules
- Flutter packages
- bridge generation
- Rust Android build output
- vcpkg Android dependencies
- NDK runtime libraries copied into `jniLibs`

## Docker In This Checkout

This checkout currently contains two Docker-related paths:

- the root-level Linux builder:
  - `Dockerfile`
  - `entrypoint.sh`
- the Android-specific local build environment:
  - `flutter/Dockerfile.android`
  - `flutter/docker/run-android-container.sh`
  - `flutter/docker/android-entrypoint.sh`
  - `flutter/docker/android-build.sh`

The root-level Docker path is documented in the repo `README.md` and works like
this:

- `docker build -t rustdesk-builder .` builds the image from the root `Dockerfile`
- `docker run ... rustdesk-builder` starts the container
- the container entrypoint runs `entrypoint.sh`
- `entrypoint.sh` prepares target directories, copies `libsciter-gtk.so`, and runs `cargo build`

The Android-specific Docker path is documented in:

- `doc/android-docker-build-environment.md`

Important caveats:

- the current GitHub workflows in `.github/workflows/` do not run either local
  Docker path directly
- the Android Docker helper signs according to the build mode: `release` output
  goes to `signed-apk/` using `flutter/android/key.jks`, while `debug` and
  `profile` output goes to `unsigned-apk/` with the Android debug key
- `flutter/docker/android-build.sh` is copied into the image at build time, so
  edits to it take effect only after the image is rebuilt
