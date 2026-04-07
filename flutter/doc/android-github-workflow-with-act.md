# Android GitHub Workflow With `act`

## Purpose

This note summarizes the approach we used across multiple local Codex sessions
to run the Android GitHub workflow with `act`.

It is a concise companion to:

- `doc/GITHUB_ACTIONS_WORKFLOWS.md`
- `doc/act-known-issues.md`

## Why We Used `act`

We used `act` to run parts of the GitHub Actions flow locally without pushing
commits just to test workflow behavior.

This was useful for:

- validating the Linux-side job graph in `.github/workflows/flutter-build.yml`
- understanding artifact flow between jobs
- exposing real build failures after the workflow wiring was fixed

It is not a perfect replacement for GitHub-hosted runners, especially for
signing, publishing, or platform-specific hosted-runner behavior.

## Approach

- treat `.github/workflows/flutter-build.yml` as the entry point instead of
  inventing a separate local build flow
- use `act` only to emulate the workflow locally, not as the source of truth
- prefer `build-rustdesk-android` over
  `build-rustdesk-android-universal` when only the `aarch64` Android matrix
  entry is enabled locally
- enable local artifact handling because this workflow passes bridge files and
  native outputs between jobs

## Known Good Command

```bash
act -W .github/workflows/flutter-build.yml \
  -j build-rustdesk-android \
  --artifact-server-path ./.act-artifacts \
  -P ubuntu-24.04=ghcr.io/catthehacker/ubuntu:act-24.04 \
  -s GITHUB_TOKEN="$(gh auth token)"
```

Expected output:

```text
signed-apk/rustdesk-1.4.6-aarch64.apk
```

## Issues We Encountered

### Artifact upload failed

Message:

```text
Unable to get ACTIONS_RUNTIME_TOKEN env variable
```

Why:

- the workflow uses `actions/upload-artifact` and `actions/download-artifact`
- `act` needs a local artifact service for that job handoff

Fix:

- add `--artifact-server-path ./.act-artifacts`

### `ubuntu-24.04` jobs were skipped

Message:

```text
Skipping unsupported platform -- Try running with `-P ubuntu-24.04=...`
```

Why:

- the workflow uses `runs-on: ubuntu-24.04`
- `act` needs an explicit image mapping for that runner label

Fix:

- add `-P ubuntu-24.04=ghcr.io/catthehacker/ubuntu:act-24.04`

### `actions/github-script` needed a token

Message:

```text
Input required and not supplied: github-token
```

Why:

- the workflow exports GitHub Actions cache variables with
  `actions/github-script@v6`
- GitHub-hosted runners provide token context automatically, but `act` does not

Fix:

- pass `-s GITHUB_TOKEN="$(gh auth token)"`

### Universal APK was the wrong local target

Why:

- `build-rustdesk-android-universal` expects multiple ABI artifacts
- the local workflow state discussed in those sessions only had the
  `aarch64-linux-android` matrix entry enabled

Fix:

- run `build-rustdesk-android` for the local `arm64-v8a` path

### After that, the remaining failure was a real build issue

Once the `act`-specific problems were fixed, the workflow progressed into the
actual Android build and then failed in Flutter package compilation.

Observed failure:

- `extended_text 13.0.0` was incompatible with the Flutter `3.24.5` toolchain
  used in that run

This mattered because it showed the workflow emulation was working well enough
to expose a real repo/toolchain compatibility problem, not just an `act`
configuration problem.
