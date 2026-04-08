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

## Workspace Sharing Decision

We also needed a clear answer for how the repo should be exposed to the
container at runtime.

Options considered:

- copy the repo from host to container on every `docker run`
- bind mount the repo into the container and keep caches on persistent mounts

Decision for local development:

- prefer a bind mount for the codebase
- keep Gradle, Pub, Cargo, and `target/` on persistent host-mounted cache paths
- treat copy-on-start as a special-purpose workflow, not the default

Why this is the better default here:

- the build scripts operate against the full repo root, not only `flutter/`
- developers need edits on the host to be immediately visible inside the
  container
- generated outputs can matter after a run, especially bridge files, APKs, and
  other build artifacts
- copying the repo every run adds startup cost and creates a sync-back problem
  for any files changed inside the container

Current implementation in `flutter/docker/run-android-container.sh`:

- the host workspace defaults to the repo root and is mounted to `/workspace`
- APK output is mounted separately to `/workspace/unsigned-apk`
- Gradle, Pub, Cargo registry, Cargo git, and `/workspace/target` are each
  mounted from persistent host cache paths
- extra bind mounts can be added with repeated `--bind HOST:CONTAINER`

This means the current runner already uses shared host/container state through
bind mounts. It does not copy the repo into the container on startup.

Important implementation detail:

- the repo is bind mounted to `/workspace`, so source files read from the repo
  root are live from the host checkout
- however, `flutter/docker/android-entrypoint.sh` and
  `flutter/docker/android-build.sh` are also copied into the image at build
  time as `/usr/local/bin/android-entrypoint.sh` and
  `/usr/local/bin/rustdesk-android-build`
- this means changing normal repo source files does not require rebuilding the
  image, but changing those two Docker helper scripts does require rebuilding
  the image before new containers will use the updated behavior

Practical rule:

- change Rust, Flutter, Gradle, or other repo inputs under the bind-mounted
  workspace: rerun the container, no image rebuild needed
- change `flutter/docker/android-entrypoint.sh`,
  `flutter/docker/android-build.sh`, or the Dockerfile itself: rebuild the
  `rustdesk-android-env` image first

Important caveat:

- bind mounting a repo from a Windows-host path can be slower than bind mounting
  from a WSL/Linux-native filesystem because Flutter, Gradle, Cargo, `vcpkg`,
  and the NDK are all heavy small-file I/O workloads
- if runtime performance becomes a problem, the first improvement should be to
  move the repo to a Linux-native filesystem before introducing a copy/sync
  workflow

Questions that determine whether the default should change:

- is the main goal an inner-loop developer workflow or a reproducible
  release-like build
- will the container run against a Windows path shared by Docker Desktop or a
  Linux-native path in WSL
- do we want files generated during `prepare` or `build-apk` to remain
  immediately visible on the host

## Runtime Flow

The runtime split is intentionally simple:

- `flutter/docker/run-android-container.sh` is the host-side launcher
- `flutter/docker/android-entrypoint.sh` is the container startup hook
- `flutter/docker/android-build.sh` is the in-container build orchestrator,
  installed in the image as `rustdesk-android-build`

End-to-end flow:

1. `run-android-container.sh` resolves host paths, creates missing output and
   cache directories, and runs `docker run`.
2. It bind mounts the repo root to `/workspace`, mounts
   `/workspace/unsigned-apk`, and mounts persistent Gradle, Pub, Cargo, and
   `target/` caches.
3. The image starts `android-entrypoint.sh` because `flutter/Dockerfile.android`
   sets it as the container `ENTRYPOINT`.
4. The entrypoint creates Android runtime files, marks the bind-mounted repo as
   a Git safe directory, and writes `flutter/android/local.properties` against
   the mounted workspace.
5. If `--auto-prepare` was passed to `run-android-container.sh`, the launcher
   sets `RUSTDESK_AUTO_PREPARE=1` and the entrypoint runs
   `rustdesk-android-build prepare` before the main command.
6. The entrypoint then `exec`s the requested command, for example
   `rustdesk-android-build build-apk arm64-v8a`.
7. `rustdesk-android-build` treats `/workspace` as the repo root when it sees
   `Cargo.toml` and `flutter/`, validates the toolchain, ensures bridge files
   and Flutter packages, builds Android dependencies and Rust artifacts, runs
   `flutter build apk`, and copies the final APK into
   `/workspace/unsigned-apk`.

Script-location implication:

- steps 3 through 7 execute the copies baked into the image, not the
  bind-mounted script files under `/workspace/flutter/docker/`
- if you update those helper scripts in the repo and only rerun the container,
  the container will still run the older copies from the previously built image
- this is easy to miss because the rest of the repo is live through the bind
  mount

Practical implication:

- because `/workspace` is a bind mount, generated bridge files, JNI libraries,
  `local.properties`, and APK outputs are written back into the host-visible
  workspace or mounted output directory

## Typical Steps

Recommended local workflow:

1. Build the image once from the repo root.

```bash
docker build --no-cache \
  -f flutter/Dockerfile.android \
  --build-arg USER_UID="$(id -u)" \
  --build-arg USER_GID="$(id -g)" \
  -t rustdesk-android-env .
```

2. Run a one-shot prepare to validate the mounted repo and generate missing
   bridge/package state.

```bash
./flutter/docker/run-android-container.sh -- rustdesk-android-build prepare
```

3. Build the unsigned APK for a target ABI.

```bash
./flutter/docker/run-android-container.sh -- \
  rustdesk-android-build build-apk arm64-v8a release
```

4. Find the output on the host under `unsigned-apk/`.

Expected output pattern:

```text
unsigned-apk/rustdesk-<version>-arm64-v8a.apk
```

Useful variants:

- skip the separate prepare command and let the entrypoint do it:

```bash
./flutter/docker/run-android-container.sh --auto-prepare -- \
  rustdesk-android-build build-apk arm64-v8a release
```

- open an interactive shell in the prepared container:

```bash
./flutter/docker/run-android-container.sh --auto-prepare -- bash
```

- override the mounted workspace if the repo has been copied to a faster
  Linux-native path:

```bash
./flutter/docker/run-android-container.sh \
  --workspace /path/to/rustdesk-fork \
  -- rustdesk-android-build build-apk arm64-v8a release
```

When script changes do require an image rebuild:

```bash
docker build \
  -f flutter/Dockerfile.android \
  --build-arg USER_UID="$(id -u)" \
  --build-arg USER_GID="$(id -g)" \
  -t rustdesk-android-env .
```

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

### FFmpeg Android dependency build failed with exit 127

The `ffmpeg:arm64-android` overlay port builds through a shell script that
invokes plain `make`, but the Docker image and WSL bootstrap package list did
not include `make`.

Fix:

- add `make` to `flutter/Dockerfile.android`
- add `make` to `flutter/setup_android_wsl_toolchain.sh` so the host bootstrap
  and Docker package set stay aligned

### Rust Android build failed because host OpenSSL headers were missing

The Rust cross-build later failed in `openssl-sys`, but the error showed
`$HOST = x86_64-unknown-linux-gnu`, which means the missing dependency was on
the Linux host side of the build graph rather than in the Android NDK.

Root cause:

- `build.rs` depends on `hbb_common`
- `hbb_common` pulls in `tokio-native-tls`
- `tokio-native-tls` uses `openssl-sys`
- the image and WSL bootstrap package list did not include `libssl-dev`, so
  `pkg-config` could not find `openssl.pc`

Fix:

- add `libssl-dev` to `flutter/Dockerfile.android`
- add `libssl-dev` to `flutter/setup_android_wsl_toolchain.sh`

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
