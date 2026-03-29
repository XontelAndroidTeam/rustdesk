# Project Understanding

## What This Project Is

This checkout is a RustDesk fork. The repository root is the real product workspace, and `flutter/` is the Flutter UI layer that sits on top of a larger Rust codebase.

Inside this folder, the Flutter package is `flutter_hbb` and `pubspec.yaml` describes it as "Your Remote Desktop Software". The app targets desktop, mobile, and some web-specific code paths.

## High-Level Architecture

- The Rust core lives in `../src` and `../libs/*`.
- The Flutter UI lives in `lib/`.
- Flutter talks to Rust through `flutter_rust_bridge`.
- Android also talks to Rust through JNI and loads a native library named `rustdesk`.

In practice, this means the Flutter app is not standalone. It depends on the parent Rust workspace, generated bridge code, protobuf definitions, and native shared libraries.

## How The Pieces Fit Together

### 1. Rust Core

The parent workspace contains the real remote-desktop logic:

- networking and rendezvous logic
- screen capture
- input injection
- clipboard and file transfer
- codecs and media handling
- configuration and built-in settings

Important locations:

- `../src`
- `../libs/scrap`
- `../libs/enigo`
- `../libs/clipboard`
- `../libs/hbb_common`

### 2. Flutter UI

The Flutter code is split by platform and concern:

- `lib/main.dart`: app entrypoint
- `lib/common/`: shared widgets and logic
- `lib/desktop/`: desktop UI
- `lib/mobile/`: mobile UI
- `lib/web/`: web-specific code
- `lib/models/`: app state and bridge-facing models
- `lib/plugin/` and `lib/utils/`: plugin and helper logic

`lib/main.dart` decides whether the app starts as desktop, mobile, connection manager, install page, or a desktop multi-window mode.
See `doc/main-dart-responsibilities.md` for a focused summary of that file's role.

### 3. Flutter <-> Rust Bridge

The bridge entrypoint is `../src/flutter_ffi.rs`.

The checked-in Dart code imports generated bridge output:

- `lib/generated_bridge.dart`
- `../src/bridge_generated*.rs`

Those generated files are not present in this checkout right now, so they are a build prerequisite.
See `doc/flutter-rust-bridge.md` for a focused explanation of how the bridge is wired and used at runtime.

### 4. Android Integration

Android loads the Rust shared library from `android/app/src/main/kotlin/ffi.kt`:

- `System.loadLibrary("rustdesk")`

The Android host layer also contains:

- `MainActivity.kt` for the Flutter method channel and Android-side feature wiring
- `MainApplication.kt` to call Rust startup hooks
- services for media projection, input, floating window, audio, and clipboard

The Android app therefore needs a built `librustdesk.so` under:

- `android/app/src/main/jniLibs/<abi>/librustdesk.so`

That folder is currently missing in this checkout, so the Android native library has not been prepared yet.

## Build-Relevant Coupling To The Parent Repo

This Flutter module depends on the repo root in several ways:

- `android/app/build.gradle` reads protobuf files from `../libs/hbb_common/protos`
- the same Gradle file runs `cargo metadata` in `../..` to locate the Rust-generated Maven repo for `rustls-platform-verifier-android`
- Rust features and native libraries are defined in the root `Cargo.toml`

So this `flutter/` folder cannot be treated as an isolated Flutter project.

## Important Build Observations From This Checkout

- `flutter/README.md` is only the default Flutter template, so it is not the source of truth for this project
- the real build knowledge is in the root README, the CI workflows, and the helper scripts in `flutter/`
- `libs/hbb_common` is a Git submodule, so submodules must be initialized
- `lib/generated_bridge.dart` is missing
- `../src/bridge_generated*.rs` is missing
- `android/app/src/main/jniLibs` is missing

## Practical Takeaway

This is a Flutter front end for a Rust-native remote desktop system. A successful build needs more than `flutter pub get`:

- the full parent repo
- the `hbb_common` submodule
- generated bridge files
- Rust toolchain and native dependencies
- Android native libraries for APK builds
