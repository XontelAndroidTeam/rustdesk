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

That command signs with your release keystore, so it needs the two files described
under [Signing](#signing) below.

Output path for that command:

- Flutter first writes the ABI-specific APK inside the repo at
  `flutter/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`
- the Docker helper then copies it to the stable host-visible path
  `signed-apk/rustdesk-<version>-arm64-v8a.apk`
- with the default `run-android-container.sh` mount layout, that final file is
  available on the host at `<repo-root>/signed-apk/`
- a `debug` or `profile` build instead lands in `<repo-root>/unsigned-apk/`

### Step-By-Step Flow

1. Validate the mounted repo and generate missing bridge/package state:

   ```bash
   ./flutter/docker/run-android-container.sh -- rustdesk-android-build prepare
   ```

2. Build the APK for the target ABI:

   ```bash
   ./flutter/docker/run-android-container.sh -- \
     rustdesk-android-build build-apk arm64-v8a release
   ```

3. Find the host output under `signed-apk/`, typically:

   ```text
   signed-apk/rustdesk-<version>-arm64-v8a.apk
   ```

   Swap `release` for `debug` to build without a keystore; that output goes to
   `unsigned-apk/` instead.

### Signing

The build mode decides the signing key. There is no flag or environment variable
to override it.

- `debug` and `profile` builds use the Android debug key and need no setup
- `release` builds sign with the keystore named by `storeFile` in
  `flutter/android/key.properties`

Both release signing inputs live at fixed repo paths, and both are already
gitignored:

| What | Path |
| --- | --- |
| Keystore | `flutter/android/key.jks` |
| Signing config | `flutter/android/key.properties` |

Create the keystore once, if you do not already have one:

```bash
keytool -genkey -v -keystore flutter/android/key.jks -alias xontel \
  -keyalg RSA -keysize 2048 -validity 10000
```

Then copy [`key.properties.example`](../android/key.properties.example) to
`flutter/android/key.properties` and fill in the secrets:

```properties
storeFile=../key.jks
storePassword=YOUR_STORE_PASSWORD
keyAlias=YOUR_KEY_ALIAS
keyPassword=YOUR_KEY_PASSWORD
```

Keep the relative `../key.jks` rather than an absolute path. Gradle resolves
`storeFile` from `flutter/android/app`, so one value works both on the host and
inside the container, with no extra mount and nothing machine-specific.

A `release` build aborts immediately, before any build work starts, if
`key.properties` is missing, has no `storeFile` entry, or names a keystore that
does not exist. The helper reads `storeFile` rather than assuming a path, so
pointing it at a keystore elsewhere works.

The same rule applies outside Docker: `MODE=release bash flutter/build_android.sh`
and a plain `flutter build apk --release` both read the same `key.properties`.

> APK location summary:
> `release` builds are signed with your keystore and copied to
> `<repo-root>/signed-apk/`, as `signed-apk/rustdesk-<version>-arm64-v8a.apk`.
> `debug` and `profile` builds are copied to `<repo-root>/unsigned-apk/`.
> Flutter's own output stays under
> `<repo-root>/flutter/build/app/outputs/flutter-apk/` as `app-<abi>-<mode>.apk`;
> the helper copies from there.

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
