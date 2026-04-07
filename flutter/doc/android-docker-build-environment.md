# Android Docker Build Environment

## Purpose

This note records why we built the `rustdesk-android-env` image and what we
had to fix to make it usable.

This is not the source of truth for Android build logic. The source of truth
remains the repo workflows and the WSL-first bootstrap/build documents under
`flutter/doc/`.

## Why We Needed This

The Android build is not a simple Flutter-only build.

It depends on:

- Flutter SDK
- Rust toolchain
- Android SDK and NDK
- `vcpkg`
- repo-root inputs and generated bridge artifacts

Setting that up repeatedly on a host machine is slow, easy to drift, and hard
to reproduce across developers. A Docker image gives us a reusable Linux-native
toolchain layer that can be built once and reused for local Android work.

## Why We Took This Approach

We took a two-layer approach:

- keep the real build flow defined by existing repo scripts and workflows
- use Docker only to package the required toolchains and system dependencies

This keeps the image focused on environment provisioning instead of inventing a
separate Android build process.

## Issues Encountered

### Flutter patch mismatch

The Dockerfile was still trying to apply the dropdown-menu patch when building
Flutter `3.24.5`, but that patch is only applicable to `3.24.4`.

Fix:

- restrict the patch gate in `flutter/Dockerfile.android` to `3.24.4`

### Container user/group collision

The image build failed when `USER_GID=1000` already existed in the base image.

Fix:

- reuse an existing group when the requested GID already exists
- create or update the container user with the requested numeric IDs
- `chown` by numeric `UID:GID` instead of assuming a matching group name

## Build Command

```bash
docker build --no-cache \
  -f flutter/Dockerfile.android \
  --build-arg USER_UID="$(id -u)" \
  --build-arg USER_GID="$(id -g)" \
  -t rustdesk-android-env .
```

Notes:

- pass `USER_UID` and `USER_GID` so files written from the container stay owned
  by the host user on bind-mounted paths
- use `--no-cache` when validating Dockerfile changes or when an old cached
  layer may still contain stale behavior
