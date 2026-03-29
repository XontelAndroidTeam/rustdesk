# Flutter <-> Rust Bridge

## Purpose

The Flutter UI does not implement the remote-desktop engine itself. It calls
into the Rust core through `flutter_rust_bridge`, which provides a typed FFI
layer between Dart and Rust.

In this repo, the bridge is split into:

- handwritten Rust API definitions in `../src/flutter_ffi.rs`
- generated Dart bindings in `lib/generated_bridge.dart`
- generated Rust glue in `../src/bridge_generated*.rs`

## Source Of Truth

The bridge entrypoint is `../src/flutter_ffi.rs`.

That file defines the Rust functions and stream types that Flutter is allowed
to use, including:

- app initialization methods such as `main_init`
- device and environment setup like `main_device_id`, `main_device_name`, and
  `main_set_home_dir`
- session lifecycle methods such as `session_add_sync` and `session_start`
- stream payloads such as `EventToUI`
- global event streaming through `start_global_event_stream`

The Rust crate expects generated bridge glue through `../src/lib.rs`, which
includes `bridge_generated` when the Flutter feature or mobile targets are
enabled.

## What The Generated Files Do

### `lib/generated_bridge.dart`

This is the generated Dart wrapper around the Rust API.

Based on the checked-in call sites, it provides typed Dart-side bridge objects
such as:

- `RustdeskImpl`
- `SessionID`
- `EventToUI`

Flutter code imports this file in `lib/models/platform_model.dart` and exposes
the generated API through `bind`.

### `../src/bridge_generated*.rs`

These generated Rust files are the marshalling layer for
`flutter_rust_bridge`.

Their job is to:

- receive FFI calls from Dart
- convert Dart values into Rust types
- call the real functions in `flutter_ffi.rs`
- convert Rust return values, async results, and streams back into forms Dart
  can consume

## Runtime Call Path

At a high level, the bridge works like this:

1. Flutter loads the Rust native library such as `librustdesk.so` or
   `librustdesk.dll`.
2. `PlatformFFI` creates `RustdeskImpl(dylib)` from the generated Dart bridge.
3. Flutter startup code calls bridge methods like `mainDeviceId`,
   `mainDeviceName`, `mainSetHomeDir`, and `mainInit`.
4. Higher-level UI code calls `bind.*` methods such as `sessionAddSync()` and
   `sessionStart()` to create and control remote sessions.
5. Rust sends results and updates back through streams:
   - global JSON event stream for app-level events
   - per-session stream carrying `Event`, `Rgba`, and `Texture` messages

That means most Flutter code does not call raw `dart:ffi` symbols directly. It
calls generated, typed methods on `bind`, and the generated bridge handles the
low-level conversion work.

## Concrete Repo Wiring

- `lib/models/platform_model.dart` imports `lib/generated_bridge.dart` for
  native platforms and `lib/web/bridge.dart` for web.
- `lib/models/native_model.dart` loads the native Rust library, constructs
  `RustdeskImpl`, and calls startup bridge methods.
- `lib/models/model.dart` uses `bind.sessionAddSync()` and
  `bind.sessionStart()` to create sessions and consume `EventToUI` stream
  messages.
- build scripts such as `flutter/run.sh`, `build.py`, and
  `flutter/docker/android-build.sh` run `flutter_rust_bridge_codegen` against
  `../src/flutter_ffi.rs`.

## Important Limitation In This Checkout

`lib/generated_bridge.dart` and `../src/bridge_generated*.rs` are not present
in this checkout right now.

So the exact generated code cannot be inspected here. This explanation is based
on:

- the handwritten Rust bridge entrypoint in `../src/flutter_ffi.rs`
- the crate wiring in `../src/lib.rs`
- the codegen commands in the build scripts
- the checked-in Dart call sites that import and use the generated bridge
