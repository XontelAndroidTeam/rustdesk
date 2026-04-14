# Flutter Documentation

This directory is the main documentation entry point for the Flutter-side
developer workflow in the Xontel fork of RustDesk.

The primary local Android path documented here is the Debian Docker workflow.

## Naming

- Use `Xontel` when referring to the shipped product, local builds, testing,
  and internal developer workflow in this checkout.
- Use `RustDesk` when referring to upstream lineage or technical names that
  still exist in code, scripts, package names, library names, and workflow
  files.

## Start Here

- Docker build path on Debian: this page
- Detailed build reference: [flutter-build-guide.md](flutter-build-guide.md)
- Product and repo structure: [project-understanding.md](project-understanding.md)

## Docker Build Path On Debian

### Build The Image

Build the Android image from the repo root:

```bash
docker build --no-cache \
  -f flutter/Dockerfile.android \
  --build-arg USER_UID="$(id -u)" \
  --build-arg USER_GID="$(id -g)" \
  -t rustdesk-android-env .
```

### Auto-Prepare Flow

Recommended one-command local build path:

```bash
./flutter/docker/run-android-container.sh --auto-prepare -- \
  rustdesk-android-build build-apk arm64-v8a release
```

Output path for that command:

- Flutter first writes the ABI-specific APK inside the repo at
  `flutter/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`
- the Docker helper then copies it to the stable host-visible path
  `unsigned-apk/rustdesk-<version>-arm64-v8a.apk`
- with the default `run-android-container.sh` mount layout, that final file is
  available on the host at `<repo-root>/unsigned-apk/`

### Step-By-Step Flow

1. Validate the mounted repo and generate missing bridge/package state:

   ```bash
   ./flutter/docker/run-android-container.sh -- rustdesk-android-build prepare
   ```

2. Build the unsigned APK for the target ABI:

   ```bash
   ./flutter/docker/run-android-container.sh -- \
     rustdesk-android-build build-apk arm64-v8a release
   ```

3. Find the host output under `unsigned-apk/`, typically:

   ```text
   unsigned-apk/rustdesk-<version>-arm64-v8a.apk
   ```

### Signing

- `release` in the helper commands above means Flutter release build mode, not
  production keystore signing
- the Docker helper temporarily swaps `signingConfigs.release` to
  `signingConfigs.debug`, so the copied APK is not signed with your production
  release keystore
- normal Gradle release signing reads `flutter/android/key.properties`
- required keys:

  ```properties
  storeFile=/absolute/path/to/release.jks
  storePassword=YOUR_STORE_PASSWORD
  keyAlias=YOUR_KEY_ALIAS
  keyPassword=YOUR_KEY_PASSWORD
  ```

- `storeFile` must point to a path that exists in the environment running
  Gradle
- for Docker, use a container-visible path such as
  `/workspace/flutter/android/release.jks` after mounting the keystore into the
  container
- if you want a true release-signed APK in Docker, do not rely on the helper's
  default signing swap; run the manual release build path described in
  [flutter-build-guide.md](flutter-build-guide.md)

> APK location summary:
> Unsigned or helper-built Docker APKs are copied to
> `<repo-root>/unsigned-apk/`, typically as
> `unsigned-apk/rustdesk-<version>-arm64-v8a.apk`.
> True release-signed APKs stay under
> `<repo-root>/flutter/build/app/outputs/flutter-apk/`.
> The signed filename depends on the Flutter command you run there, commonly
> `app-release.apk` or `app-<abi>-release.apk` when using `--split-per-abi`.

### Rebuild The Image When

Rebuild the image when Docker helper scripts or the Android Dockerfile change:

- `flutter/Dockerfile.android`
- `flutter/docker/android-entrypoint.sh`
- `flutter/docker/android-build.sh`

See [android-docker-build-environment.md](android-docker-build-environment.md)
for cache mounts, runtime flow, rebuild conditions, and Docker-specific
troubleshooting.

## Detailed References

- [flutter-build-guide.md](flutter-build-guide.md): full build prerequisites,
  version pins, signing notes, and Docker overview
- [android-docker-build-environment.md](android-docker-build-environment.md):
  Docker environment rationale, runtime flow, caches, and rebuild rules
- [project-understanding.md](project-understanding.md): how Flutter, Rust,
  Android, generated bridge code, and repo-root dependencies fit together
- [flutter-rust-bridge.md](flutter-rust-bridge.md): bridge generation inputs,
  generated files, and runtime wiring
- [android-tablet-testing-guide.md](android-tablet-testing-guide.md): post-build
  Android validation on a device
- [GITHUB_ACTIONS_WORKFLOWS.md](GITHUB_ACTIONS_WORKFLOWS.md): CI workflow map

## Background / History

These notes stay available for context, but they are not the main entry point
for the current Docker-on-Debian local build path.

- [android-build-learning-journey.md](android-build-learning-journey.md)
- [android-debug-build-plan-wsl.md](android-debug-build-plan-wsl.md)
- [android-toolchain-bootstrap-plan-wsl.md](android-toolchain-bootstrap-plan-wsl.md)
- [android-github-workflow-with-act.md](android-github-workflow-with-act.md)
- [act-known-issues.md](act-known-issues.md)
