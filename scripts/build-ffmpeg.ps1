#Requires -Version 5.1
<#
.SYNOPSIS
    Build a minimal, statically-linked FFmpeg for Windows.

.DESCRIPTION
    Windows equivalent of scripts/build-ffmpeg.sh.
    Downloads the pinned FFmpeg release, configures it with the same
    minimal feature set, and stages static archives + headers into .\dist\
    - ready for build.rs to link against.

    Build environment: MSYS2 with MinGW-w64 (x86_64).
    MinGW-w64 produces .a archives matching what build.rs expects.

    Install MSYS2 from https://www.msys2.org/, then inside an MSYS2
    MinGW64 shell run:
        pacman -S --needed mingw-w64-x86_64-gcc mingw-w64-x86_64-nasm make pkg-config

    Output (mirrors build-ffmpeg.sh):
        .\dist\lib\libavformat.a
        .\dist\lib\libavcodec.a
        .\dist\lib\libavutil.a
        .\dist\lib\libswscale.a
        .\dist\lib\libswresample.a
        .\dist\include\libav*\...
        .\dist\link_flags.txt
        .\dist\ffmpeg-version.txt

    Re-running is idempotent; wipes .\dist\ before reinstalling.

.PARAMETER Reconfigure
    Force re-running ./configure even if a previous configuration exists.
#>
[CmdletBinding()]
param(
    [switch]$Reconfigure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function ConvertTo-MsysPath([string]$WinPath) {
    $p = $WinPath.Replace('\', '/')
    if ($p -match '^([A-Za-z]):(.*)') {
        return '/' + $Matches[1].ToLower() + $Matches[2]
    }
    return $p
}

function Invoke-Msys2Bash([string]$Script) {
    # Write the script to a temp file - avoids quoting hazards with -c.
    $tmp = [System.IO.Path]::GetTempFileName() + '.sh'
    try {
        [System.IO.File]::WriteAllText($tmp, $Script)
        $tmpMsys = ConvertTo-MsysPath $tmp
        $env:MSYSTEM = 'MINGW64'   # selects MinGW-w64 64-bit toolchain
        & $Bash --login -c "bash '$tmpMsys'"
        if ($LASTEXITCODE -ne 0) {
            throw "MSYS2 script failed (exit $LASTEXITCODE)"
        }
    } finally {
        Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Navigate to repo root
# ---------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root      = Split-Path -Parent $ScriptDir
Push-Location $Root
try {

# ---------------------------------------------------------------------------
# Read pinned version
# ---------------------------------------------------------------------------
$VersionFile = Join-Path $Root 'ffmpeg-version.txt'
if (-not (Test-Path $VersionFile)) {
    throw "ffmpeg-version.txt not found at $VersionFile"
}
$Version = (Get-Content $VersionFile -Raw).Trim()
if ([string]::IsNullOrEmpty($Version)) {
    throw "ffmpeg-version.txt is empty; refusing to build"
}
$VersionNoPrefix = $Version -replace '^n', ''

$SourcesDir = Join-Path $Root 'sources'
$SourceDir  = Join-Path $SourcesDir "ffmpeg-$Version"
$DistDir    = Join-Path $Root 'dist'
$BuildDir   = Join-Path $Root "build\$Version"

Write-Host "==> ffmpeg-embed: building ffmpeg $Version" -ForegroundColor Cyan
Write-Host "    SOURCE_DIR = $SourceDir"
Write-Host "    BUILD_DIR  = $BuildDir"
Write-Host "    DIST_DIR   = $DistDir"

# ---------------------------------------------------------------------------
# Locate MSYS2
# ---------------------------------------------------------------------------
$Msys2Candidates = @(
    'C:\msys64',
    'C:\msys2',
    "$env:USERPROFILE\scoop\apps\msys2\current",
    "$env:LOCALAPPDATA\Programs\msys2",
    'C:\tools\msys64'
)
$Msys2Root = $null
foreach ($candidate in $Msys2Candidates) {
    if (Test-Path (Join-Path $candidate 'usr\bin\bash.exe')) {
        $Msys2Root = $candidate
        break
    }
}
if (-not $Msys2Root) {
    throw @"
MSYS2 not found. Checked: $($Msys2Candidates -join ', ')
Install from https://www.msys2.org/, then inside an MSYS2 MinGW64 shell:
    pacman -S --needed mingw-w64-x86_64-gcc mingw-w64-x86_64-nasm make pkg-config
"@
}
$Bash = Join-Path $Msys2Root 'usr\bin\bash.exe'
Write-Host "    MSYS2      = $Msys2Root" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Verify required tools inside MSYS2 MinGW64
# ---------------------------------------------------------------------------
Write-Host "==> Checking build tools" -ForegroundColor Cyan
Invoke-Msys2Bash @'
set -euo pipefail
missing=0
for tool in gcc make pkg-config nasm; do
    if command -v "$tool" >/dev/null 2>&1; then
        echo "  ok: $tool ($(command -v $tool))"
    else
        echo "  MISSING: $tool"
        missing=1
    fi
done
if [ "$missing" -eq 1 ]; then
    echo ""
    echo "Install missing tools inside an MSYS2 MinGW64 shell:"
    echo "  pacman -S --needed mingw-w64-x86_64-gcc mingw-w64-x86_64-nasm make pkg-config"
    exit 1
fi
'@

# ---------------------------------------------------------------------------
# Fetch source
# ---------------------------------------------------------------------------
if (-not (Test-Path $SourceDir)) {
    New-Item -ItemType Directory -Force -Path $SourcesDir | Out-Null

    $Tarball = Join-Path $SourcesDir "ffmpeg-$Version.tar.gz"
    if (-not (Test-Path $Tarball)) {
        $Url = "https://ffmpeg.org/releases/ffmpeg-$VersionNoPrefix.tar.gz"
        Write-Host "==> Fetching $Url" -ForegroundColor Cyan
        Invoke-WebRequest -Uri $Url -OutFile $Tarball -UseBasicParsing
    }

    Write-Host "==> Extracting $Tarball" -ForegroundColor Cyan
    # Windows 10 1803+ ships tar.exe; fall back to MSYS2 tar otherwise.
    if (Get-Command tar -CommandType Application -ErrorAction SilentlyContinue) {
        & tar -xzf $Tarball -C $SourcesDir
        if ($LASTEXITCODE -ne 0) { throw "tar extraction failed" }
    } else {
        $msysTar     = ConvertTo-MsysPath $Tarball
        $msysSources = ConvertTo-MsysPath $SourcesDir
        Invoke-Msys2Bash "tar -xzf '$msysTar' -C '$msysSources'"
    }

    # Rename from ffmpeg-X.Y to ffmpeg-nX.Y to match the pinned tag form.
    $ExtractedDir = Join-Path $SourcesDir "ffmpeg-$VersionNoPrefix"
    if ((Test-Path $ExtractedDir) -and (-not (Test-Path $SourceDir))) {
        Rename-Item -Path $ExtractedDir -NewName "ffmpeg-$Version"
    }
}

# ---------------------------------------------------------------------------
# Configure + Build inside MSYS2 MinGW64
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

$MsysSourceDir    = ConvertTo-MsysPath $SourceDir
$MsysBuildDir     = ConvertTo-MsysPath $BuildDir
$MsysDistDir      = ConvertTo-MsysPath $DistDir
$ReconfigureFlag  = if ($Reconfigure) { '1' } else { '0' }

# Feature set mirrors build-ffmpeg.sh exactly.
$BuildScript = @"
set -euo pipefail

DECODERS='h264,hevc,vp8,vp9,av1,mpeg4,mjpeg,aac,opus,flac,mp3,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s32le,pcm_f32le,vorbis,alac'
ENCODERS='flac,aac,pcm_s16le,pcm_s24le,pcm_f32le'
DEMUXERS='mov,matroska,avi,mpegts,flv,wav,flac,mp3,ogg,aac,aiff'
MUXERS='ipod,mp4,flac,wav,ogg,aac'
PARSERS='h264,hevc,vp8,vp9,av1,mpeg4video,mjpeg,aac,opus,flac,mpegaudio'
BSFS='h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc'
PROTOCOLS='file,pipe'

mkdir -p '$MsysBuildDir'
cd '$MsysBuildDir'

if [ ! -f config.mak ] || [ '$ReconfigureFlag' = '1' ]; then
    echo '==> Configuring'
    '$MsysSourceDir/configure' \
        --prefix='$MsysDistDir' \
        --arch=x86_64 \
        --target-os=mingw32 \
        --disable-shared \
        --enable-static \
        --disable-programs \
        --disable-doc \
        --disable-htmlpages \
        --disable-manpages \
        --disable-podpages \
        --disable-txtpages \
        --disable-gpl \
        --disable-nonfree \
        --disable-network \
        --disable-autodetect \
        --disable-avfilter \
        --disable-avdevice \
        --disable-everything \
        --enable-w32threads \
        "--enable-decoder=`$DECODERS" \
        "--enable-demuxer=`$DEMUXERS" \
        "--enable-parser=`$PARSERS" \
        "--enable-bsf=`$BSFS" \
        "--enable-protocol=`$PROTOCOLS" \
        --enable-swscale \
        --enable-swresample \
        "--enable-encoder=`$ENCODERS" \
        "--enable-muxer=`$MUXERS" \
        --cc=gcc \
        --cxx=g++ \
        --ld=gcc \
        --ar=ar
fi

CORES=`$(nproc 2>/dev/null || echo 4)
echo "==> Building with -j`$CORES"
make -j"`$CORES"

echo '==> Installing into $MsysDistDir'
make install
"@

Write-Host "==> Configuring and building inside MSYS2 MinGW64" -ForegroundColor Cyan
Invoke-Msys2Bash $BuildScript

# ---------------------------------------------------------------------------
# Trim dist/ (mirrors build-ffmpeg.sh)
# ---------------------------------------------------------------------------
$ShareDir     = Join-Path $DistDir 'share'
$PkgconfigDir = Join-Path $DistDir 'lib\pkgconfig'
if (Test-Path $ShareDir)     { Remove-Item -Recurse -Force $ShareDir }
if (Test-Path $PkgconfigDir) { Remove-Item -Recurse -Force $PkgconfigDir }

# ---------------------------------------------------------------------------
# Emit link_flags.txt and version stamp
# ---------------------------------------------------------------------------
$LinkFlags  = '-Ldist/lib'
$LinkFlags += ' -lavformat -lavcodec -lswscale -lswresample -lavutil'
# Windows runtime deps for the MinGW-w64 build:
#   ws2_32  - Winsock (pipe protocol + some demuxer paths)
#   bcrypt  - avutil CPRNG on Windows (replaces getrandom/arc4random)
#   secur32 - SSPI, pulled in by some avformat paths
$LinkFlags += ' -lws2_32 -lbcrypt -lsecur32'

[System.IO.File]::WriteAllText((Join-Path $DistDir 'link_flags.txt'), $LinkFlags)
Copy-Item -Path (Join-Path $Root 'ffmpeg-version.txt') `
          -Destination (Join-Path $DistDir 'ffmpeg-version.txt') -Force

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host "`n==> Done. dist/ contents:" -ForegroundColor Green
foreach ($dir in @('lib', 'include')) {
    $full = Join-Path $DistDir $dir
    if (Test-Path $full) {
        Get-ChildItem -Path $full -Recurse -File -Depth 2 |
            Sort-Object FullName |
            ForEach-Object { '    ' + $_.FullName.Substring($DistDir.Length + 1) }
    }
}

$Archives = Get-ChildItem -Path (Join-Path $DistDir 'lib') -Filter '*.a' -ErrorAction SilentlyContinue
if ($Archives) {
    $TotalMB = [math]::Round(($Archives | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
    Write-Host ("`n    Total static archive size: {0:N1} MB" -f $TotalMB) -ForegroundColor Green
}

} finally {
    Pop-Location
}
