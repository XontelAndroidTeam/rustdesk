# Flutter Build Guide

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

## Docker Android Build

This repo now includes a containerized Android build path:

- `flutter/Dockerfile.android`
- `flutter/docker/android-build.sh`

Build the image from the repository root so the Docker build context can still see the full repo:

```bash
docker build -f flutter/Dockerfile.android -t rustdesk-android .
```

Run it by mounting the repository root at `/workspace`:

```bash
docker run --rm -it -v "$PWD:/workspace" rustdesk-android
```

Useful environment variables:

- `ANDROID_ABIS=arm64-v8a,armeabi-v7a`
- `ANDROID_BUILD_MODE=release`
- `ANDROID_ARTIFACT=apk` or `appbundle`
- `ANDROID_SPLIT_PER_ABI=1`
- `GENERATE_BRIDGE=auto`

The container copies finished artifacts to `out/android` in the mounted repository.
