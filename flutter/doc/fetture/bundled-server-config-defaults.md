# Bundled ServerConfig Defaults

## Purpose

This note documents the feature discussed and implemented in this session:
shipping default RustDesk server settings inside the app bundle so a fresh
install starts with prefilled server configuration.

## Goal

The goal was to keep the change small and low-risk:

- avoid Android-specific changes unless necessary
- prefer Dart changes over Gradle, Kotlin, Java, or Rust changes
- avoid changing the user experience for existing users
- keep the default data in version control

## Final Design

The implementation uses a Flutter asset plus a Dart startup hook.

Files involved:

- `flutter/assets/server_config.json`
- `flutter/lib/models/native_model.dart`

The asset format intentionally stays close to `ServerConfig.decode()`:

```json
{
  "host": "108.129.241.59:21116",
  "relay": "108.129.241.59:21117",
  "api": "http://108.129.241.59:21114",
  "key": "Lsuq0K50eXJ5PyE5jbnHNlU4067xdhPkmbkmLhxqiBY="
}
```

## Runtime Behavior

The startup hook runs after `mainInit()` in `PlatformFFI.init()`.

It reads the current saved values for:

- `custom-rendezvous-server`
- `relay-server`
- `api-server`
- `key`

It only applies the bundled values when all four saved values are empty after
trimming whitespace.

If any one of those fields already has a user value, the bundled asset is not
applied.

If the asset is missing or malformed, the app logs the error and continues
without a user-facing message.

## User Experience Impact

Expected behavior:

- fresh installs or empty config start with prefilled server settings
- existing user settings remain unchanged
- no extra prompt, toast, or warning is shown

This means the only visible UX difference is that server settings are already
filled in for first-time setup instead of being blank.

## Scope Decisions

Decisions made during this session:

- apply defaults only when all four server fields are empty together
- keep the asset checked into Git
- keep the asset format close to `ServerConfig`
- allow blank values in the asset
- keep the change applicable to all Flutter targets

Explicitly excluded from this feature:

- `av1-test`
- `local-ip-addr`

`local-ip-addr` is runtime-derived from the device network environment and
should not be shipped as a bundled default.

## Docker Build Impact

This feature does not require rebuilding the Android Docker image.

Why:

- the changed files are ordinary repo source files under the bind-mounted
  workspace
- `flutter/docker/run-android-container.sh` mounts the repo to `/workspace`
- the container sees those source edits on the next run

For this feature, the practical workflow is:

1. keep the existing `rustdesk-android-env` image
2. rerun the container
3. run the Android build again

Rebuild the image only if one of these changes:

- `flutter/Dockerfile.android`
- `flutter/docker/android-entrypoint.sh`
- `flutter/docker/android-build.sh`

Pulling an image is also unnecessary unless a newer remote image is intentionally
being used instead of the local one already built for this repo.

## Implementation Notes

One integration issue appeared during implementation:

- the first draft referenced `bind` inside `flutter/lib/models/native_model.dart`
- that file does not define `bind`
- the correct bridge handle in that scope is `_ffiBind`

The fix was to call `_ffiBind.mainGetOptionSync()` and
`_ffiBind.mainSetOption()` directly inside the startup helper.

## Verification Status

Code-level checks completed:

- confirmed `mainGetOptionSync()` exists in the Flutter bridge
- confirmed the asset path is covered by `flutter: assets: - assets/`
- confirmed the JSON keys match `ServerConfig.decode()`
- confirmed the startup timing happens after native init

Not completed in this session:

- full end-to-end Android build and runtime verification

If later validation is needed, the first practical check is to build the APK,
install it on a device or emulator with empty existing config, and confirm the
server settings page shows the bundled values on first launch.
