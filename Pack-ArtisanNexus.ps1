# Artisan Nexus — staging ZIP for WoW Interface\AddOns\ArtisanNexus
# Usage: powershell -ExecutionPolicy Bypass -File Pack-ArtisanNexus.ps1
#
# Copies only runtime addon folders/files (no repo metadata, scripts, or tooling).

$ErrorActionPreference = "Stop"
$RepoRoot = $PSScriptRoot
$TocPath = Join-Path $RepoRoot "ArtisanNexus.toc"
if (-not (Test-Path -LiteralPath $TocPath)) {
    Write-Error "ArtisanNexus.toc not found at: $TocPath"
}

$Version = "dev"
foreach ($line in Get-Content -LiteralPath $TocPath -Encoding UTF8) {
    if ($line -match '^## Version:\s*(.+)$') {
        $Version = $Matches[1].Trim()
        break
    }
}

$BuildRoot = Join-Path $RepoRoot "build"
$StageDir = Join-Path $BuildRoot "ArtisanNexus"
if (Test-Path -LiteralPath $StageDir) {
    Remove-Item -LiteralPath $StageDir -Recurse -Force
}
New-Item -ItemType Directory -Path $StageDir -Force | Out-Null

$CopyNames = @(
    "Core.lua", "Config.lua", "embeds.xml", "Bindings.xml", "ArtisanNexus.toc",
    "Locales", "Modules", "Media", "libs"
)
foreach ($name in $CopyNames) {
    $src = Join-Path $RepoRoot $name
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Warning "Skip missing: $name"
        continue
    }
    Copy-Item -LiteralPath $src -Destination (Join-Path $StageDir $name) -Recurse -Force
}

# Wago / CurseForge reject zips with extra addon TOCs under libs.
$LibsDir = Join-Path $StageDir "libs"
if (Test-Path -LiteralPath $LibsDir) {
    Get-ChildItem -Path $LibsDir -Filter "*.toc" -File -Recurse | Remove-Item -Force
}

$LibJunk = @(
    "README.md", "README.textile", "changelog.txt", "CHANGES.txt", "LICENSE.txt",
    "Changelog-libdatabroker-1-1-v1.1.4.txt", "embeds.xml", "Bindings.xml", "Ace3.lua",
    "LibDeflate\.xml"
)
foreach ($rel in $LibJunk) {
    $p = Join-Path $LibsDir ($rel -replace '/', '\')
    if (Test-Path -LiteralPath $p) {
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    }
}

$ZipName = "ArtisanNexus-$Version.zip"
$ZipPath = Join-Path $BuildRoot $ZipName
if (Test-Path -LiteralPath $ZipPath) {
    Remove-Item -LiteralPath $ZipPath -Force
}
Compress-Archive -LiteralPath $StageDir -DestinationPath $ZipPath -Force

Write-Host "Staged: $StageDir"
Write-Host "ZIP:    $ZipPath"
$bytes = (Get-Item -LiteralPath $ZipPath).Length
Write-Host ("Size:   {0:N0} bytes" -f $bytes)
