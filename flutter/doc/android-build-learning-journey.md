# Android Build Learning Journey

## Purpose

This document records the path we took to understand how to build the Android
RustDesk client locally in WSL.

It is not the primary build procedure. The procedural documents are:

- `doc/flutter-build-guide.md`
- `doc/android-debug-build-plan-wsl.md`
- `doc/android-toolchain-bootstrap-plan-wsl.md`
- `doc/android-docker-build-environment.md`
- `doc/android-github-workflow-with-act.md`

This file captures the reasoning behind those documents so future work can
start from the decisions already made.

The Docker environment note and the `act` workflow note document different
approaches from the WSL-first path captured here.

## Simple Timeline

- 2026-03-30: started with a WSL-first investigation, created the bootstrap and
  debug-build planning documents, and recorded the first `install-flutter`
  failures and fixes
- 2026-04-01 to 2026-04-02: explored running
  `.github/workflows/flutter-build.yml` locally with `act`, fixed the local
  artifact, runner-mapping, and token issues, and then reached a real Flutter
  package compatibility failure
- 2026-04-07: revisited the Docker path, fixed the stale Flutter patch gate and
  the container UID/GID collision in `flutter/Dockerfile.android`, built the
  `rustdesk-android-env` image successfully, and documented that approach

## Starting Point

The original goal was simple:

- build and run a debug Android app locally
- avoid relying on `flutter/Dockerfile.android`
- understand the real repo build path before designing a better Docker image

That forced us to move from "how do we run one command?" to "what does this
repo actually need before an Android APK can exist?"

## What We Learned Early

### This Is Not A Flutter-Only Android Build

The Android client depends on more than Flutter code.

It needs:

- Flutter UI code under `flutter/`
- Rust code from the repo root
- generated flutter-rust-bridge output
- Android-packaged native Rust shared libraries
- Android native dependencies built through `vcpkg`

That means `flutter build apk` alone is not enough on a clean checkout.

### The Full Repo Root Matters

The build is wired against the full repository, not only the `flutter/`
subdirectory.

Important examples:

- Android Gradle reads protobuf inputs from `libs/hbb_common/protos`
- Gradle invokes `cargo metadata`
- the Flutter Android project sets `flutter { source '../..' }`

This was an important correction to the initial mental model.

### Generated Files Are Part Of The Build Story

The checked-in Flutter and Rust bridge outputs may be absent in a local
checkout.

Important generated artifacts:

- `flutter/lib/generated_bridge.dart`
- `src/bridge_generated*.rs`

That means the bridge-generation path has to be treated as a first-class build
step, not as an implementation detail.

## Source Of Truth Decisions

### Existing Workflows Matter More Than AI-Written One-Off Scripts

We explicitly decided not to treat these as the source of truth:

- `flutter/Dockerfile.android`
- `flutter/docker/android-build.sh`

Instead, we chose to derive the real build flow from:

- `.github/workflows/bridge.yml`
- `.github/workflows/flutter-build.yml`
- `flutter/build_android_deps.sh`
- `flutter/build_fdroid.sh`
- `flutter/ndk_arm64.sh`
- `flutter/ndk_arm.sh`
- `flutter/ndk_x64.sh`
- `flutter/ndk_x86.sh`

Why:

- CI usually captures the build that actually works
- helper scripts already encode ABI-specific behavior
- reusing working repo logic is safer than creating a parallel build system

### Reuse Existing Scripts Where They Already Encode Repo Knowledge

We decided the future Android debug wrapper should orchestrate existing helper
scripts instead of replacing them.

That led to two planned layers:

- one-time toolchain/bootstrap setup
- repeatable project build/run orchestration

This split is now reflected in:

- `flutter/setup_android_wsl_toolchain.sh`
- planned `flutter/run_android_debug_wsl.sh`

## Environment Decisions

### WSL First, Docker Later

We chose to make WSL the first target environment and Docker the second.

Why:

- local troubleshooting is easier in WSL than inside an image build
- a good Docker image should package a proven local flow
- this lowers the risk of debugging container problems before the build logic
  itself is understood

### Ubuntu 24.04 LTS On WSL 2

We chose Ubuntu 24.04 LTS as the assumed WSL distro.

Why:

- it matches the repo Android CI host
- it keeps package names and behavior aligned with CI
- it maps cleanly to a future `ubuntu:24.04` Docker base image

### Linux-Native SDKs And Toolchains Inside WSL

We decided not to drive the Android build from Windows SDK paths while running
inside WSL.

Instead, WSL should own Linux-native installs of:

- Flutter
- Android SDK
- Android NDK
- Rust
- `vcpkg`

Why:

- helper scripts assume Linux host layouts
- Flutter, SDK, and NDK binaries are host-specific
- this keeps WSL and future Docker layouts aligned

## Storage And Filesystem Lessons

### Building From `/mnt/c` Is Possible, But Not Ideal

We explicitly discussed whether the repo must be copied into the WSL filesystem.

The conclusion was:

- building from `/mnt/c/...` is allowed
- it is slower and somewhat more fragile than building from WSL ext4

Why:

- Flutter, Gradle, Cargo, `vcpkg`, and the NDK all generate heavy small-file
  I/O
- Windows-mounted filesystems are usually slower for that pattern
- permissions, symlinks, and executable bits are more likely to behave oddly

### Toolchains And Caches Should Stay In WSL Even If The Repo Does Not

Even if the repo stays on `/mnt/c/...`, we decided the Linux toolchains and
caches should live in WSL-native paths.

Recommended examples:

- `~/sdk/flutter`
- `~/Android/Sdk`
- `~/sdk/vcpkg`
- `~/.cargo`
- `~/.gradle`
- `~/.pub-cache`
- `~/.cache/rustdesk-target`
- `~/.cache/vcpkg-downloads`

This was an important compromise because storage is tight, but performance and
reliability still matter.

### Docker Should Share The Repo With A Bind Mount, Not A Per-Run Copy

When we returned to the Docker path, we explicitly compared two runtime models:

- copy the repo from host to container on each run
- bind mount the repo into the container and persist caches separately

The local-development decision was:

- use a bind mount for the repo workspace
- persist build caches outside the repo
- avoid per-run repo copies unless we specifically need snapshot-style isolation

Why:

- the Android build depends on the full repo root, so a partial copy or
  Flutter-only mount is the wrong model
- a bind mount keeps host edits and container actions in the same working tree
- copying every run would add startup time and would require an explicit
  strategy for syncing generated files back to the host
- the runtime wrapper already supports a better split: shared workspace plus
  separately mounted caches

The practical caveat is performance:

- bind mounting from a Windows-backed filesystem can still be slower than using
  a Linux-native filesystem
- if that becomes a problem, moving the repo to WSL ext4 is a better first
  response than adding copy-on-start complexity

### The Real Storage Cost Is Mostly Not Ubuntu Itself

We also discussed whether a very lightweight Ubuntu variant was needed.

The conclusion was that the large storage consumers are more likely to be:

- Flutter SDKs
- Android SDK and NDK
- Cargo caches
- Gradle caches
- `vcpkg` downloads and build trees

So the recommended path stayed:

- standard Ubuntu 24.04 LTS
- lean package installation
- careful cache placement and reuse

## Internet And Reproducibility Lessons

### Limited Internet Changes The Shape Of The Scripts

Because the connection is limited, we decided the scripts should strongly favor
reuse over downloading.

That affects the design in several ways:

- bootstrap work should be separate from the day-to-day build script
- scripts should be idempotent
- caches should persist
- repeated bridge generation should be avoided unless necessary
- one ABI at a time should be the default

### Version Pins Should Come From Repo Workflows

We captured version pins from the existing workflows instead of choosing new
ones ad hoc.

Important examples:

- Android build Flutter: `3.24.5`
- bridge-generation Flutter: `3.22.3`
- Rust: `1.75`
- `cargo-ndk`: `3.1.2`
- `flutter_rust_bridge_codegen`: `1.80.1`
- Android NDK: `r28c`
- `vcpkg` commit: `120deac3062162151622ca4860575a33844ba10b`

This matters for learning because it reinforces a useful rule:

- when a repo already has CI, use CI pins first and invent less

## Artifacts Created Along The Way

This learning path already produced:

- `doc/flutter-build-guide.md`
- `doc/android-debug-build-plan-wsl.md`
- `doc/android-toolchain-bootstrap-plan-wsl.md`
- `flutter/setup_android_wsl_toolchain.sh`

Together they now define:

- what the build needs
- how the WSL environment should be prepared
- how the future debug wrapper should behave

## Next Learning Milestone

The next major step is to implement:

- `flutter/run_android_debug_wsl.sh`

That script should prove the end-to-end local debug flow by reusing the repo's
existing Android helper scripts and the bridge-generation path already
identified here.

## Practical Takeaway

The main lesson from this journey is that the Android RustDesk client is best
understood as a coordinated Flutter + Rust + generated-bridge + Android-native
packaging workflow.

Once that is accepted, the structure of the solution becomes much clearer:

- bootstrap the Linux host once
- reuse the repo's existing build helpers
- keep version pins aligned with CI
- keep Docker as packaging of a known-good WSL process

## Session Update: 2026-03-30

Current confirmed progress in the WSL bootstrap work:

- Ubuntu has been installed on WSL
- WSL environment configuration is now in progress
- the setup was smooth through host and Rust bootstrap, with the first reported issue appearing during `install-flutter`
- completed `./flutter/setup_android_wsl_toolchain.sh install-host`
- completed `./flutter/setup_android_wsl_toolchain.sh install-rust`
- first attempt at `./flutter/setup_android_wsl_toolchain.sh install-flutter` failed with a `tar` archive-path error
- the bootstrap script was corrected after that failure

What those completed steps mean:

- the required Ubuntu host packages should now be installed
- Rust `1.75` should now be available through `rustup`
- `cargo-ndk` `3.1.2` should now be installed
- `cargo-expand` `1.0.95` should now be installed
- `flutter_rust_bridge_codegen` `1.80.1` should now be installed

Encounter recorded during `install-flutter`:

- observed error:
  `tar (child): ... /root/.cache/rustdesk-bootstrap-downloads/flutter_linux_3.24.5-stable.tar.xz: Cannot open: No such file or directory`
- root cause:
  `download_with_cache` was used inside command substitution, but `log()` wrote progress text to stdout, so the returned archive path was polluted by the log line
- fix applied:
  `log()` now writes to stderr, which keeps command-substitution return values clean
- impact:
  this fix should also protect first-download paths in `install-rust`, `install-android-sdk`, and `install-ndk`

Second encounter recorded during `install-flutter`:

- observed error:
  `ERROR: Flutter patch does not apply cleanly to /home/user/sdk/flutter`
- root cause:
  the bootstrap script treated the local Flutter patch as mandatory for every version `>= 3.24.4`, but Flutter `3.24.5` can contain an equivalent upstream fix even when the local patch no longer applies cleanly
- fix applied:
  the script now checks the extracted Flutter source for the equivalent `dropdown_menu.dart` fix and skips the patch when that fix is already present
- impact:
  `install-flutter` should now proceed on Flutter `3.24.5` without failing on a no-longer-applicable patch

Diagnostic improvement added after those encounters:

- the bootstrap script now supports verbose logging with `--verbose` or `VERBOSE=1`
- verbose mode enables bash command tracing and extra debug lines for cache reuse, archive selection, SDK detection, and toolchain state
- recommended retry pattern for troubleshooting:
  `./flutter/setup_android_wsl_toolchain.sh --verbose install-flutter`

Remaining bootstrap steps expected from the current WSL plan:

- rerun `./flutter/setup_android_wsl_toolchain.sh install-flutter`
- `./flutter/setup_android_wsl_toolchain.sh install-android-sdk`
- `./flutter/setup_android_wsl_toolchain.sh install-ndk`
- `./flutter/setup_android_wsl_toolchain.sh install-vcpkg`
- `./flutter/setup_android_wsl_toolchain.sh env`
- `./flutter/setup_android_wsl_toolchain.sh check`
