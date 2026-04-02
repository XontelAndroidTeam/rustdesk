# `act` Known Issues

## 1. Artifact Upload Fails With Missing Runtime Token

Problem:

- local `act` run fails during `actions/upload-artifact`

Message:

```text
Unable to get ACTIONS_RUNTIME_TOKEN env variable
```

Cause:

- this workflow passes generated files between jobs with `actions/upload-artifact` and `actions/download-artifact`
- under `act`, artifact upload and download require the local artifact service to be enabled

Fix:

- add `--artifact-server-path ./.act-artifacts` to the `act` command

Command line:

```bash
act -W .github/workflows/flutter-build.yml -j build-rustdesk-android-universal --artifact-server-path ./.act-artifacts
```

## 2. Jobs Are Skipped Because `ubuntu-24.04` Is Unsupported

Problem:

- local `act` run skips Android jobs before the build can continue

Message:

```text
Skipping unsupported platform -- Try running with `-P ubuntu-24.04=...`
```

Cause:

- this workflow uses `runs-on: ubuntu-24.04`
- `act` needs an explicit Docker image mapping for that runner label

Fix:

- add `-P ubuntu-24.04=ghcr.io/catthehacker/ubuntu:act-24.04`
- if the smaller image is not sufficient, try `ghcr.io/catthehacker/ubuntu:full-24.04`

Command line:

```bash
act -W .github/workflows/flutter-build.yml -j build-rustdesk-android-universal --artifact-server-path ./.act-artifacts -P ubuntu-24.04=ghcr.io/catthehacker/ubuntu:act-24.04
```

## Working Command

```bash
act -W .github/workflows/flutter-build.yml -j build-rustdesk-android-universal --artifact-server-path ./.act-artifacts -P ubuntu-24.04=ghcr.io/catthehacker/ubuntu:act-24.04 -s GITHUB_TOKEN=YOUR_TOKEN
```

## 3. `actions/github-script` Fails Because `github-token` Is Missing

Problem:

- local `act` run fails at the step named `Export GitHub Actions cache environment variables`

Message:

```text
Input required and not supplied: github-token
```

Cause:

- the workflow uses `actions/github-script@v6` in `.github/workflows/flutter-build.yml`
- on GitHub-hosted runners, `github.token` is provided automatically from `GITHUB_TOKEN`
- under `act`, you need to provide `GITHUB_TOKEN` explicitly as a secret for actions that expect it

Fix:

- add a `GITHUB_TOKEN` secret to the `act` run
- minimal form: `-s GITHUB_TOKEN=YOUR_TOKEN`

Command line:

```bash
act -W .github/workflows/flutter-build.yml -j build-rustdesk-android-universal --artifact-server-path ./.act-artifacts -P ubuntu-24.04=ghcr.io/catthehacker/ubuntu:act-24.04 -s GITHUB_TOKEN=YOUR_TOKEN
```

Notes:

- the `Error response from daemon: a prune operation is already running` line from `free-disk-space` is not the failing issue here; that step is written to tolerate that error
- after adding `GITHUB_TOKEN`, later release-publish steps may still require a real token with sufficient permissions because this workflow keeps release-related behavior enabled when `upload-artifact` is `true`

## 4. Build Only `aarch64` / `arm64-v8a`

Goal:

- build only the `arm64-v8a` APK instead of the universal APK

Use this job:

- run `build-rustdesk-android`
- do not run `build-rustdesk-android-universal`

Why:

- `build-rustdesk-android` builds a single ABI-specific APK
- `build-rustdesk-android-universal` expects multiple ABI artifacts and combines them into one universal APK

Current local setup:

- in this workspace, the `armv7-linux-androideabi` and `x86_64-linux-android` entries in `.github/workflows/flutter-build.yml` are commented out
- that leaves only the `aarch64-linux-android` matrix entry active
- that maps to Android ABI `arm64-v8a`

Command line:

```bash
act -W .github/workflows/flutter-build.yml -j build-rustdesk-android --artifact-server-path ./.act-artifacts -P ubuntu-24.04=ghcr.io/catthehacker/ubuntu:act-24.04 -s GITHUB_TOKEN=YOUR_TOKEN
```

Expected output:

```text
signed-apk/rustdesk-1.4.6-aarch64.apk
```
