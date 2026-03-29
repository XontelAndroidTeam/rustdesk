# `lib/main.dart` Responsibilities

## Purpose

`lib/main.dart` is the Flutter entrypoint and startup coordinator for the app.
It does not implement the product's core remote-desktop features directly. Its
main job is to decide what kind of app instance to launch, initialize shared
runtime state, and build the root Flutter shell around the correct screen.

## High-Level Responsibilities

### 1. Route Startup By Platform And Launch Mode

`main()` inspects platform and command-line arguments, then chooses which app
mode to start:

- normal desktop main window
- desktop multi-window child instance
- connection manager window
- install page
- mobile startup flow

This makes `main.dart` the top-level traffic controller for the Flutter app.

### 2. Initialize Shared Environment And Native Bridge State

Before showing UI, `initEnv()` prepares global runtime dependencies:

- initializes `platformFFI`
- initializes global FFI state
- registers event handlers for native and desktop events
- synchronizes the system window theme

This is the common startup layer used by the main app, mobile app, multi-window
screens, and install/connection-manager variants.

### 3. Launch The Correct App Shell

`main.dart` contains separate startup flows for each major runtime shape:

- `runMainApp()` for the normal desktop app
- `runMobileApp()` for mobile
- `runMultiWindow()` for desktop child windows such as remote desktop, file
  transfer, camera view, port forward, and terminal
- `runConnectionManagerScreen()` for the compact connection-manager experience
- `runInstallPage()` for the installer UI

Each flow performs the initialization and window setup required for that mode.

### 4. Manage Desktop Window Lifecycle

For desktop variants, `main.dart` is responsible for window-level behavior such
as:

- title-bar mode
- prevent-close behavior
- restoring saved window positions
- showing, hiding, and focusing windows
- always-on-top and resizable settings
- connection-manager show/hide behavior

This is why the file imports and coordinates `window_manager` and
`desktop_multi_window`.

### 5. Build The Root Flutter App Container

`App`, `_runApp()`, and related helpers define the root Flutter shell:

- `GetMaterialApp`
- localization delegates and supported locales
- light/dark theme wiring
- toast/navigation wrappers
- top-level providers for shared models
- selection of the correct home page for desktop, web, or mobile

The file is therefore responsible for app composition, not feature-specific UI
details.

### 6. Apply Global UI And Input Behavior

The file also owns app-wide behavior that should exist regardless of which page
is active:

- reacting to platform brightness changes
- updating theme mode and syncing it back to native code
- tracking mobile orientation changes
- normalizing text scaling
- installing a top-level keyboard listener for shared key state

These are cross-cutting concerns that belong near the root of the widget tree.

## What `main.dart` Does Not Mainly Own

`main.dart` does not contain the actual product logic for remote desktop, file
transfer, camera viewing, terminal sessions, or server pages. Those live in the
screen, page, model, and platform-specific modules imported by this file.

In practice:

- `lib/main.dart` decides what to launch and how to wrap it
- feature modules implement the actual behavior of those screens
