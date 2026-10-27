#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
    Heap Hunter installer for Windows.

.DESCRIPTION
    Downloads the latest release binary from GitHub, installs it into a directory
    on PATH, and wires up the environment. Can also build from source locally.

.PARAMETER Local
    Build from the local source tree instead of downloading a release binary.

.PARAMETER Uninstall
    Remove the installed binary, PATH entries, and config file created by this installer.

.PARAMETER Help
    Show this help message.

.EXAMPLE
    .\install.ps1
    Download the latest release binary.

.EXAMPLE
    .\install.ps1 -Local
    Build from source (requires Zig 0.16.0+).

.EXAMPLE
    .\install.ps1 -Uninstall
    Uninstall Heap Hunter.
#>

[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [switch]$Local,
    
    [Parameter(ParameterSetName = 'Uninstall')]
    [switch]$Uninstall,
    
    [Parameter(ParameterSetName = 'Help')]
    [switch]$Help
)

# Configuration
$RepoSlug = "AmeyaKasture/heap_hunter"
$BinName = "hunt"
$InstallDir = if ($env:HEAP_HUNTER_INSTALL_DIR) { $env:HEAP_HUNTER_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "Programs\heap-hunter\bin" }
$EnvFile = if ($env:HEAP_HUNTER_ENV_FILE) { $env:HEAP_HUNTER_ENV_FILE } else { Join-Path $env:USERPROFILE ".heap_hunter_env.ps1" }
$IndexDirValue = if ($env:HEAP_HUNTER_INDEX_DIR) { $env:HEAP_HUNTER_INDEX_DIR } else { "index" }
$SortingBudgetMb = if ($env:HEAP_HUNTER_SORTING_BUDGET_MB) { [int]$env:HEAP_HUNTER_SORTING_BUDGET_MB } else { 4096 }
$OptimizeMode = "ReleaseFast"
$ApiUrl = "https://api.github.com/repos/$RepoSlug/releases/latest"
$BinFile = "hunt.exe"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Colors
function Write-Step {
    param([string]$Message)
    Write-Host "==> " -ForegroundColor Blue -NoNewline
    Write-Host $Message
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[ok] " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[warn] " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Write-Err {
    param([string]$Message)
    Write-Host "[error] " -ForegroundColor Red -NoNewline
    Write-Host $Message
}

function Write-Die {
    param([string]$Message)
    Write-Err $Message
    exit 1
}

function Show-Usage {
    Write-Host @"
Heap Hunter installer (Windows)

Usage:
  .\install.ps1                Download latest release binary
  .\install.ps1 -Local         Build from local source tree (requires Zig 0.16.0+)
  .\install.ps1 -Uninstall     Remove installed binary, PATH entry and config file
  .\install.ps1 -Help          Show this help

Environment:
  HEAP_HUNTER_INSTALL_DIR      Install directory (default: $env:LOCALAPPDATA\Programs\heap-hunter\bin)
  HEAP_HUNTER_ENV_FILE         Environment file written (default: %USERPROFILE%\.heap_hunter_env.ps1)
  HEAP_HUNTER_CONFIG_FILE      Config file location
  HEAP_HUNTER_INDEX_DIR        index-dir value in config (default: index)
  HEAP_HUNTER_SORTING_BUDGET_MB sorting-budget-mb in config (default: 4096)
"@
}

function Test-VersionGe {
    param(
        [string]$Version1,
        [string]$Version2
    )
    $v1Parts = $Version1.Split('.') | ForEach-Object { [int]$_ }
    $v2Parts = $Version2.Split('.') | ForEach-Object { [int]$_ }
    $maxLen = [Math]::Max($v1Parts.Length, $v2Parts.Length)
    for ($i = 0; $i -lt $maxLen; $i++) {
        $a = if ($i -lt $v1Parts.Length) { $v1Parts[$i] } else { 0 }
        $b = if ($i -lt $v2Parts.Length) { $v2Parts[$i] } else { 0 }
        if ($a -gt $b) { return $true }
        if ($a -lt $b) { return $false }
    }
    return $true
}

function Get-PlatformInfo {
    $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    switch ($arch) {
        "X64" { $ArchTag = "amd64" }
        "Arm64" { $ArchTag = "arm64" }
        default { Write-Die "Unsupported architecture: $arch" }
    }
    $Platform = "windows-$ArchTag"
    $AssetName = "heap_hunter-$Platform.zip"
    return @{
        Platform = $Platform
        ArchTag = $ArchTag
        AssetName = $AssetName
        BinFile = $BinFile
    }
}

function Resolve-ConfigPath {
    if ($env:HEAP_HUNTER_CONFIG_FILE) {
        $script:ConfigFile = $env:HEAP_HUNTER_CONFIG_FILE
        $script:ConfigDir = Split-Path -Parent $script:ConfigFile
        return
    }
    $script:ConfigDir = Join-Path $env:APPDATA "hunt"
    $script:ConfigFile = Join-Path $script:ConfigDir "config.json"
}

function Install-FromRelease {
    $platformInfo = Get-PlatformInfo
    $assetName = $platformInfo.AssetName
    $tmpDir = Join-Path $env:TEMP "heap_hunter_$(Get-Random)"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    
    try {
        Write-Step "Resolving latest release for windows-$($platformInfo.ArchTag)"
        $tag = ""
        $digest = ""
        $downloadUrl = ""
        
        try {
            $headers = @{
                "Accept" = "application/vnd.github+json"
                "User-Agent" = "HeapHunter-Installer"
            }
            $release = Invoke-RestMethod -Uri $ApiUrl -Headers $headers -Method Get -ErrorAction Stop
            $tag = $release.tag_name
            foreach ($asset in $release.assets) {
                if ($asset.name -eq $assetName) {
                    $downloadUrl = $asset.browser_download_url
                    if ($asset.digest) {
                        $digest = $asset.digest -replace "^sha256:", ""
                    }
                    break
                }
            }
            if (-not $downloadUrl) {
                $availableAssets = ($release.assets | ForEach-Object { $_.name }) -join ", "
                Write-Err "No release asset for windows-$($platformInfo.ArchTag) ($assetName)"
                Write-Err "Available assets: $availableAssets"
                exit 1
            }
            Write-Ok "Found release $tag"
        }
        catch {
            Write-Warn "Could not query GitHub API, falling back to latest release redirect"
            $downloadUrl = "https://github.com/$RepoSlug/releases/latest/download/$assetName"
        }
        
        Write-Step "Downloading $assetName"
        $assetPath = Join-Path $tmpDir $assetName
        $curlExe = Get-Command curl.exe -ErrorAction SilentlyContinue
        if ($curlExe) {
            try {
                & curl.exe -L -fsSL --retry 3 --connect-timeout 30 -o $assetPath $downloadUrl
                if ($LASTEXITCODE -ne 0) {
                    throw "curl exited with code $LASTEXITCODE"
                }
                Write-Ok "Downloaded $assetName"
            }
            catch {
                Write-Die "Failed to download $downloadUrl"
            }
        }
        else {
            try {
                Invoke-WebRequest -Uri $downloadUrl -OutFile $assetPath -UseBasicParsing -ErrorAction Stop
                Write-Ok "Downloaded $assetName"
            }
            catch {
                Write-Die "Failed to download $downloadUrl"
            }
        }
        
        if ($digest) {
            Write-Step "Verifying checksum"
            $hash = (Get-FileHash -Path $assetPath -Algorithm SHA256).Hash.ToLower()
            if ($hash -ne $digest.ToLower()) {
                Write-Die "Checksum mismatch for $assetName (expected $digest, got $hash)"
            }
            Write-Ok "Checksum verified (sha256 $($hash.Substring(0,16))...)"
        }
        else {
            Write-Warn "No checksum published for this asset, skipping verification"
        }
        
        Write-Step "Extracting"
        $extractDir = Join-Path $tmpDir "extract"
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        try {
            Expand-Archive -Path $assetPath -DestinationPath $extractDir -Force -ErrorAction Stop
        }
        catch {
            Write-Die "Failed to extract $assetName"
        }
        
        $foundExe = Get-ChildItem -Path $extractDir -Filter $BinFile -Recurse | Select-Object -First 1
        if (-not $foundExe) {
            Write-Die "Could not find $BinFile inside $assetName"
        }
        
        Install-Binary -SourcePath $foundExe.FullName
    }
    finally {
        if (Test-Path $tmpDir) {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-FromSource {
    $zonPath = Join-Path $ScriptDir "build.zig.zon"
    
    Write-Step "Checking the Zig toolchain"
    $zigCmd = Get-Command zig -ErrorAction SilentlyContinue
    if (-not $zigCmd) {
        Write-Die "zig not found in PATH, install Zig 0.16.0 or newer: https://ziglang.org/download/"
    }
    $zigVersion = (& zig version).Trim()
    Write-Ok "zig $zigVersion"
    
    if (Test-Path $zonPath) {
        $zonContent = Get-Content $zonPath -Raw
        if ($zonContent -match '\.minimum_zig_version\s*=\s*"([^"]+)"') {
            $minVersion = $Matches[1]
            if (Test-VersionGe -Version1 $zigVersion -Version2 $minVersion) {
                Write-Ok "zig $zigVersion satisfies the required minimum $minVersion"
            }
            else {
                Write-Die "zig $zigVersion is older than the required minimum $minVersion"
            }
        }
        else {
            Write-Warn "No .minimum_zig_version declared in build.zig.zon, skipping the version check"
        }
    }
    else {
        Write-Warn "build.zig.zon not found in $ScriptDir, skipping the version check"
    }
    
    Write-Step "Checking the Zig dependency tree"
    if (Test-Path $zonPath) {
        $deps = @()
        $inDeps = $false
        foreach ($line in (Get-Content $zonPath)) {
            if ($line -match '\.dependencies\s*=\s*\.') {
                if ($line -match '\.\{\s*\}') {
                    $inDeps = $false
                }
                else {
                    $inDeps = $true
                }
                continue
            }
            if ($inDeps -and $line -match '^\s*\}') {
                $inDeps = $false
                continue
            }
            if ($inDeps -and $line -match '\.name\s*=') {
                if ($line -match '\.name\s*=\s*\.([a-zA-Z0-9_]+)') {
                    $deps += $Matches[1]
                }
            }
        }
        if ($deps.Count -gt 0) {
            foreach ($dep in $deps) {
                Write-Host "    dependency: $dep"
            }
        }
        else {
            Write-Host "    no external dependencies declared"
        }
    }
    
    Push-Location $ScriptDir
    try {
        Write-Step "Fetching Zig dependencies"
        & zig build --fetch 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Die "zig dependency tree could not be resolved"
        }
        Write-Ok "All Zig dependencies are satisfied"
        
        Write-Step "Building the production binary ($OptimizeMode)"
        & zig build "-Doptimize=$OptimizeMode" 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Die "Build failed"
        }
        Write-Ok "Build finished"
    }
    finally {
        Pop-Location
    }
    
    $builtExe = Join-Path $ScriptDir "zig-out\bin\$BinFile"
    if (-not (Test-Path $builtExe)) {
        Write-Die "Built binary not found at $builtExe"
    }
    Install-Binary -SourcePath $builtExe
}

function Install-Binary {
    param([string]$SourcePath)
    
    if (-not (Test-Path $SourcePath)) {
        Write-Die "Built binary not found at $SourcePath"
    }
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }
    $destPath = Join-Path $InstallDir $BinFile
    Copy-Item -Path $SourcePath -Destination $destPath -Force
    Write-Ok "Installed $BinName -> $destPath"
}

function Setup-Path {
    Write-Step "Adding $InstallDir to PATH"
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $userPath) { $userPath = "" }
    if ($userPath -notlike "*$InstallDir*") {
        if ($userPath -eq "") {
            $newPath = $InstallDir
        }
        else {
            $newPath = $userPath.TrimEnd(';') + ";" + $InstallDir
        }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Ok "Added to user PATH"
    }
    else {
        Write-Ok "Already in PATH"
    }
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "User") + ";" + [Environment]::GetEnvironmentVariable("Path", "Machine")
}

function Create-Config {
    Write-Step "Creating the config file"
    Resolve-ConfigPath
    if (Test-Path $script:ConfigFile) {
        Write-Warn "Config file already exists, leaving it unchanged: $($script:ConfigFile)"
        return
    }
    if (-not (Test-Path $script:ConfigDir)) {
        New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
    }
    $indexEscaped = $IndexDirValue -replace '\\', '\\' -replace '"', '\"'
    $configJson = @"
{
  "index-dir": "$indexEscaped",
  "sorting-budget-mb": $SortingBudgetMb
}
"@
    Set-Content -Path $script:ConfigFile -Value $configJson -Encoding UTF8
    Write-Ok "Config file created: $($script:ConfigFile)"
}

function Verify-Install {
    $exePath = Join-Path $InstallDir $BinFile
    try {
        $version = & $exePath --version 2>&1 | Select-Object -First 1
        Write-Ok "Verified: $version"
    }
    catch {
        Write-Die "$BinName failed to run after installation"
    }
}

function Show-Summary {
    Write-Host ""
    Write-Ok "Heap Hunter installed successfully"
    Write-Host ""
    Write-Host "Config file:"
    Write-Host "    $($script:ConfigFile)"
    Write-Host "    index-dir:          $IndexDirValue"
    Write-Host "    sorting-budget-mb:  $SortingBudgetMb"
    Write-Host ""
    Write-Host "Index location (index-dir `"$IndexDirValue`" is resolved relative to the current directory):"
    Write-Host "    hunt index <dump.hprof>     ->  .\$IndexDirValue\<dump-name>.idx\"
    Write-Host "    hunt overview <dump.hprof>  ->  .\$IndexDirValue\<dump-name>.idx\"
    Write-Host "    hunt info <dump.hprof>      ->  .\$IndexDirValue\<dump-name>.idx\"
    Write-Host "    hunt info                   ->  .\$IndexDirValue"
    Write-Host ""
    Write-Host "Override per run with:  $BinName <command> --index-dir <dir>"
    Write-Host ""
    Write-Host "Open a new terminal for PATH changes to take effect, then run:"
    Write-Host ""
    Write-Host "    hunt --help"
    Write-Host ""
}

function Uninstall-HeapHunter {
    Write-Step "Removing the installed binary"
    $exePath = Join-Path $InstallDir $BinFile
    if (Test-Path $exePath) {
        Remove-Item -Path $exePath -Force
        Write-Ok "Removed $exePath"
    }
    else {
        Write-Host "    Nothing to remove at $exePath"
    }
    
    Write-Step "Removing from PATH"
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -and $userPath -like "*$InstallDir*") {
        $pathParts = $userPath -split ';' | Where-Object { $_ -ne "" -and $_ -ne $InstallDir }
        $newPath = $pathParts -join ';'
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Ok "Removed from user PATH"
    }
    else {
        Write-Host "    No PATH entry found"
    }
    
    Write-Step "Removing the config file"
    Resolve-ConfigPath
    if (Test-Path $script:ConfigFile) {
        $backup = "$($script:ConfigFile).bak"
        Remove-Item -Path $backup -Force -ErrorAction SilentlyContinue
        Move-Item -Path $script:ConfigFile -Destination $backup -Force
        Write-Ok "Removed $($script:ConfigFile) (backup: $backup)"
    }
    else {
        Write-Host "    No config file at $($script:ConfigFile)"
    }
    
    Write-Host ""
    Write-Ok "Heap Hunter uninstalled"
    Write-Host ""
}

# Main
if ($Help) {
    Show-Usage
    exit 0
}

if ($Uninstall) {
    Uninstall-HeapHunter
    exit 0
}

if ($Local) {
    Install-FromSource
}
else {
    Install-FromRelease
}

Setup-Path
Create-Config
Verify-Install
Show-Summary
