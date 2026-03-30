[CmdletBinding()]
param(
    [ValidateSet('arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86')]
    [string]$Abi = 'arm64-v8a',

    [string]$DeviceId,

    [ValidateSet('Release', 'Debug')]
    [string]$RustProfile = 'Release',

    [string]$VcpkgRoot,
    [string]$AndroidSdkRoot,
    [string]$AndroidNdkRoot,
    [string]$FlutterSdk,

    [switch]$BuildOnly,
    [switch]$SkipBridge,
    [switch]$SkipPubGet,
    [switch]$SkipVcpkg,
    [switch]$SkipRust,
    [switch]$SkipRustupTarget
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$FlutterDir = Join-Path $RepoRoot 'flutter'
$AndroidDir = Join-Path $FlutterDir 'android'
$JniLibsRoot = Join-Path $AndroidDir 'app\src\main\jniLibs'
$PubspecPath = Join-Path $FlutterDir 'pubspec.yaml'
$PubspecLockPath = Join-Path $FlutterDir 'pubspec.lock'
$BridgeDartPath = Join-Path $FlutterDir 'lib\generated_bridge.dart'
$IosBridgeHeaderPath = Join-Path $FlutterDir 'ios\Runner\bridge_generated.h'
$MacosBridgeHeaderPath = Join-Path $FlutterDir 'macos\Runner\bridge_generated.h'

function Write-Section {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message"
}

function Fail {
    param([string]$Message)
    throw $Message
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = $RepoRoot
    )

    Push-Location $WorkingDirectory
    try {
        Write-Host "PS> $FilePath $($ArgumentList -join ' ')"
        & $FilePath @ArgumentList
        if ($LASTEXITCODE -ne 0) {
            Fail "Command failed with exit code $LASTEXITCODE: $FilePath $($ArgumentList -join ' ')"
        }
    } finally {
        Pop-Location
    }
}

function Invoke-Cargo {
    param(
        [string[]]$ArgumentList,
        [string]$WorkingDirectory = $RepoRoot
    )

    Invoke-External -FilePath $script:CargoExe -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory
}

function Invoke-Flutter {
    param(
        [string[]]$ArgumentList,
        [string]$WorkingDirectory = $FlutterDir
    )

    Invoke-External -FilePath $script:FlutterExe -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory
}

function Parse-LocalProperties {
    param([string]$Path)

    $props = @{}
    if (-not (Test-Path $Path)) {
        return $props
    }

    foreach ($line in Get-Content -Path $Path) {
        if ($line -match '^\s*([^=]+?)\s*=\s*(.*)\s*$') {
            $key = $matches[1]
            $value = $matches[2] -replace '\\\\', '\'
            $props[$key] = $value
        }
    }
    return $props
}

function Get-FirstCommandPath {
    param([string]$Name)

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        return $null
    }
    return $cmd.Source
}

function Resolve-ExistingPath {
    param([string[]]$Candidates)

    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }
    return $null
}

function Find-LatestNdk {
    param([string]$SdkRoot)

    if ([string]::IsNullOrWhiteSpace($SdkRoot)) {
        return $null
    }

    $ndkRoot = Join-Path $SdkRoot 'ndk'
    if (-not (Test-Path $ndkRoot)) {
        return $null
    }

    $dirs = Get-ChildItem -Path $ndkRoot -Directory | Sort-Object Name -Descending
    if ($dirs.Count -eq 0) {
        return $null
    }
    return $dirs[0].FullName
}

function Ensure-Command {
    param(
        [string]$Name,
        [string[]]$InstallArguments
    )

    $path = Get-FirstCommandPath -Name $Name
    if ($null -ne $path) {
        return $path
    }

    if ($null -eq $InstallArguments -or $InstallArguments.Count -eq 0) {
        Fail "Required command '$Name' was not found."
    }

    Write-Section "Installing missing tool: $Name"
    Invoke-Cargo -ArgumentList $InstallArguments
    $path = Get-FirstCommandPath -Name $Name
    if ($null -eq $path) {
        Fail "Command '$Name' is still unavailable after install."
    }
    return $path
}

function Get-AndroidConfig {
    param([string]$SelectedAbi)

    switch ($SelectedAbi) {
        'arm64-v8a' {
            return @{
                RustTarget = 'aarch64-linux-android'
                FlutterTarget = 'android-arm64'
                VcpkgTriplet = 'arm64-android'
                NdkRuntimeDir = 'aarch64-linux-android'
                RustFeatures = 'flutter,hwcodec'
                RustProfileDir = 'release'
            }
        }
        'armeabi-v7a' {
            return @{
                RustTarget = 'armv7-linux-androideabi'
                FlutterTarget = 'android-arm'
                VcpkgTriplet = 'arm-neon-android'
                NdkRuntimeDir = 'arm-linux-androideabi'
                RustFeatures = 'flutter,hwcodec'
                RustProfileDir = 'release'
            }
        }
        'x86_64' {
            return @{
                RustTarget = 'x86_64-linux-android'
                FlutterTarget = 'android-x64'
                VcpkgTriplet = 'x64-android'
                NdkRuntimeDir = 'x86_64-linux-android'
                RustFeatures = 'flutter'
                RustProfileDir = 'release'
            }
        }
        'x86' {
            return @{
                RustTarget = 'i686-linux-android'
                FlutterTarget = 'android-x86'
                VcpkgTriplet = 'x86-android'
                NdkRuntimeDir = 'i686-linux-android'
                RustFeatures = 'flutter'
                RustProfileDir = 'release'
            }
        }
        default {
            Fail "Unsupported ABI: $SelectedAbi"
        }
    }
}

function Test-BridgePresent {
    if (-not (Test-Path $BridgeDartPath)) {
        return $false
    }

    $bridgeRs = Get-ChildItem -Path (Join-Path $RepoRoot 'src') -Filter 'bridge_generated*.rs' -ErrorAction SilentlyContinue
    return ($bridgeRs | Measure-Object).Count -gt 0
}

function Copy-FileOrDelete {
    param(
        [string]$Source,
        [string]$Destination
    )

    if (Test-Path $Source) {
        Copy-Item -Path $Source -Destination $Destination -Force
    } elseif (Test-Path $Destination) {
        Remove-Item -Path $Destination -Force
    }
}

function Invoke-BridgeGeneration {
    param([switch]$CompatExtendedText)

    $pubspecBackup = Join-Path $env:TEMP "rustdesk-pubspec-$PID.yaml"
    $lockBackup = Join-Path $env:TEMP "rustdesk-pubspec-lock-$PID.lock"
    $lockExisted = Test-Path $PubspecLockPath
    $pubspecContent = Get-Content -Path $PubspecPath -Raw

    Copy-Item -Path $PubspecPath -Destination $pubspecBackup -Force
    if ($lockExisted) {
        Copy-Item -Path $PubspecLockPath -Destination $lockBackup -Force
    }

    try {
        if ($CompatExtendedText) {
            $patched = $pubspecContent -replace 'extended_text:\s*14\.0\.0', 'extended_text: 13.0.0'
            if ($patched -ne $pubspecContent) {
                Set-Content -Path $PubspecPath -Value $patched -NoNewline
            }
        }

        Invoke-Flutter -ArgumentList @('pub', 'get')
        Invoke-External -FilePath $script:BridgeCodegenExe -WorkingDirectory $FlutterDir -ArgumentList @(
            '--rust-input', (Join-Path $RepoRoot 'src\flutter_ffi.rs'),
            '--dart-output', (Join-Path $FlutterDir 'lib\generated_bridge.dart'),
            '--c-output', $MacosBridgeHeaderPath
        )

        if (Test-Path $MacosBridgeHeaderPath) {
            Copy-Item -Path $MacosBridgeHeaderPath -Destination $IosBridgeHeaderPath -Force
        }
    } finally {
        Copy-FileOrDelete -Source $pubspecBackup -Destination $PubspecPath
        if ($lockExisted) {
            Copy-FileOrDelete -Source $lockBackup -Destination $PubspecLockPath
        } elseif (Test-Path $PubspecLockPath) {
            Remove-Item -Path $PubspecLockPath -Force
        }

        Remove-Item -Path $pubspecBackup -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $lockBackup -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-Bridge {
    if ($SkipBridge) {
        return
    }

    if (Test-BridgePresent) {
        Write-Host "Bridge files already exist."
        return
    }

    Write-Section "Generating flutter_rust_bridge files"

    try {
        Invoke-BridgeGeneration
    } catch {
        $pubspecContent = Get-Content -Path $PubspecPath -Raw
        if ($pubspecContent -match 'extended_text:\s*14\.0\.0') {
            Write-Warning "Bridge generation failed once. Retrying with temporary extended_text compatibility patch."
            Invoke-BridgeGeneration -CompatExtendedText
        } else {
            throw
        }
    }

    if (-not (Test-BridgePresent)) {
        Fail "Bridge generation did not produce all expected files."
    }
}

function Ensure-VcpkgDeps {
    param([hashtable]$Config)

    if ($SkipVcpkg) {
        return
    }

    Write-Section "Building Android vcpkg dependencies for $Abi"
    Invoke-External -FilePath $script:VcpkgExe -WorkingDirectory $RepoRoot -ArgumentList @(
        'install',
        '--triplet', $Config.VcpkgTriplet,
        "--x-install-root=$script:VcpkgInstalledRoot"
    )

    $armNeonDir = Join-Path $script:VcpkgInstalledRoot 'arm-neon-android'
    $armDir = Join-Path $script:VcpkgInstalledRoot 'arm-android'
    if ($Abi -eq 'armeabi-v7a' -and (Test-Path $armNeonDir) -and -not (Test-Path $armDir)) {
        Move-Item -Path $armNeonDir -Destination $armDir
    }
}

function Ensure-RustArtifacts {
    param([hashtable]$Config)

    if ($SkipRust) {
        return
    }

    if (-not $SkipRustupTarget) {
        Write-Section "Adding Rust target $($Config.RustTarget)"
        Invoke-External -FilePath $script:RustupExe -ArgumentList @('target', 'add', $Config.RustTarget)
    }

    Write-Section "Building Rust Android library for $Abi"

    $cargoArgs = @('ndk', '--platform', '21', '--target', $Config.RustTarget)
    if ($RustProfile -eq 'Release') {
        $cargoArgs += 'build'
        $cargoArgs += '--release'
        $profileDir = 'release'
    } else {
        $cargoArgs += 'build'
        $profileDir = 'debug'
    }
    $cargoArgs += '--features'
    $cargoArgs += $Config.RustFeatures

    $oldCFlags = $env:CFLAGS
    $oldCxxFlags = $env:CXXFLAGS
    try {
        if ($Abi -eq 'x86') {
            $env:CFLAGS = '-DBROKEN_CLANG_ATOMICS'
            $env:CXXFLAGS = '-DBROKEN_CLANG_ATOMICS'
        }
        Invoke-Cargo -ArgumentList $cargoArgs
    } finally {
        $env:CFLAGS = $oldCFlags
        $env:CXXFLAGS = $oldCxxFlags
    }

    $rustLibPath = Join-Path $RepoRoot "target\$($Config.RustTarget)\$profileDir\liblibrustdesk.so"
    if (-not (Test-Path $rustLibPath)) {
        Fail "Rust library not found: $rustLibPath"
    }

    $jniDir = Join-Path $JniLibsRoot $Abi
    $runtimePath = Join-Path $script:NdkPrebuiltRoot "sysroot\usr\lib\$($Config.NdkRuntimeDir)\libc++_shared.so"
    if (-not (Test-Path $runtimePath)) {
        Fail "NDK runtime not found: $runtimePath"
    }

    New-Item -ItemType Directory -Path $jniDir -Force | Out-Null
    Copy-Item -Path $rustLibPath -Destination (Join-Path $jniDir 'librustdesk.so') -Force
    Copy-Item -Path $runtimePath -Destination (Join-Path $jniDir 'libc++_shared.so') -Force
}

function Ensure-FlutterDependencies {
    if ($SkipPubGet) {
        return
    }

    Write-Section "Running flutter pub get"
    Invoke-Flutter -ArgumentList @('pub', 'get')
}

function Start-FlutterDebugRun {
    param([hashtable]$Config)

    Write-Section "Starting Flutter Android debug build"
    if ($BuildOnly) {
        Invoke-Flutter -ArgumentList @('build', 'apk', '--debug', '--target-platform', $Config.FlutterTarget)
    } else {
        $args = @('run', '--debug', '--target-platform', $Config.FlutterTarget)
        if (-not [string]::IsNullOrWhiteSpace($DeviceId)) {
            $args += '-d'
            $args += $DeviceId
        }
        Invoke-Flutter -ArgumentList $args
    }
}

$localProps = Parse-LocalProperties -Path (Join-Path $AndroidDir 'local.properties')

$FlutterSdk = Resolve-ExistingPath @(
    $FlutterSdk,
    $env:FLUTTER_ROOT,
    $localProps['flutter.sdk'],
    (Split-Path (Get-FirstCommandPath -Name 'flutter') -Parent | ForEach-Object { Join-Path $_ '..' })
)
$AndroidSdkRoot = Resolve-ExistingPath @(
    $AndroidSdkRoot,
    $env:ANDROID_SDK_ROOT,
    $env:ANDROID_HOME,
    $localProps['sdk.dir']
)
$AndroidNdkRoot = Resolve-ExistingPath @(
    $AndroidNdkRoot,
    $env:ANDROID_NDK_HOME,
    $env:ANDROID_NDK_ROOT,
    (Find-LatestNdk -SdkRoot $AndroidSdkRoot)
)
$VcpkgRoot = Resolve-ExistingPath @(
    $VcpkgRoot,
    $env:VCPKG_ROOT,
    'C:\vcpkg',
    (Join-Path $env:USERPROFILE 'vcpkg')
)

if ([string]::IsNullOrWhiteSpace($FlutterSdk)) {
    Fail "Flutter SDK not found. Pass -FlutterSdk or set flutter/android/local.properties."
}
if ([string]::IsNullOrWhiteSpace($AndroidSdkRoot)) {
    Fail "Android SDK not found. Pass -AndroidSdkRoot or set flutter/android/local.properties."
}
if ([string]::IsNullOrWhiteSpace($AndroidNdkRoot)) {
    Fail "Android NDK not found. Pass -AndroidNdkRoot or install an SDK NDK package."
}
if ([string]::IsNullOrWhiteSpace($VcpkgRoot)) {
    Fail "vcpkg not found. Pass -VcpkgRoot or set VCPKG_ROOT."
}

$FlutterExe = Resolve-ExistingPath @(
    (Join-Path $FlutterSdk 'bin\flutter.bat'),
    (Get-FirstCommandPath -Name 'flutter')
)
$CargoExe = Resolve-ExistingPath @(
    (Get-FirstCommandPath -Name 'cargo')
)
$RustupExe = Resolve-ExistingPath @(
    (Get-FirstCommandPath -Name 'rustup')
)
$VcpkgExe = Resolve-ExistingPath @(
    (Join-Path $VcpkgRoot 'vcpkg.exe'),
    (Get-FirstCommandPath -Name 'vcpkg')
)
$BridgeCodegenExe = Ensure-Command -Name 'flutter_rust_bridge_codegen' -InstallArguments @(
    'install', 'flutter_rust_bridge_codegen',
    '--version', '1.80.1',
    '--features', 'uuid',
    '--locked'
)
$CargoNdkExe = Ensure-Command -Name 'cargo-ndk' -InstallArguments @(
    'install', 'cargo-ndk',
    '--version', '3.1.2',
    '--locked'
)

if ($null -eq $FlutterExe) { Fail "flutter executable not found." }
if ($null -eq $CargoExe) { Fail "cargo executable not found." }
if ($null -eq $RustupExe) { Fail "rustup executable not found." }
if ($null -eq $VcpkgExe) { Fail "vcpkg executable not found under $VcpkgRoot." }

$VcpkgInstalledRoot = Join-Path $VcpkgRoot 'installed'
$ndkPrebuiltRoot = Get-ChildItem -Path (Join-Path $AndroidNdkRoot 'toolchains\llvm\prebuilt') -Directory | Select-Object -First 1
if ($null -eq $ndkPrebuiltRoot) {
    Fail "No NDK prebuilt host toolchain found under $AndroidNdkRoot"
}
$script:NdkPrebuiltRoot = $ndkPrebuiltRoot.FullName

Write-Host "RepoRoot       : $RepoRoot"
Write-Host "FlutterSdk     : $FlutterSdk"
Write-Host "AndroidSdkRoot : $AndroidSdkRoot"
Write-Host "AndroidNdkRoot : $AndroidNdkRoot"
Write-Host "VcpkgRoot      : $VcpkgRoot"
Write-Host "Abi            : $Abi"
Write-Host "RustProfile    : $RustProfile"

$config = Get-AndroidConfig -SelectedAbi $Abi

Ensure-Bridge
Ensure-FlutterDependencies
Ensure-VcpkgDeps -Config $config
Ensure-RustArtifacts -Config $config
Start-FlutterDebugRun -Config $config
