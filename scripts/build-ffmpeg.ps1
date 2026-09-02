#Requires -Version 5.1
<#
.SYNOPSIS
    Build a minimal, statically-linked FFmpeg for Windows.

.DESCRIPTION
    Windows equivalent of scripts/build-ffmpeg.sh.
    Downloads the pinned FFmpeg release, configures it with the same
    minimal feature set, and stages static archives + headers into .\dist\
    - ready for build.rs to link against.

    Build environment: MSVC for the compiler, MSYS2 for the shell.

    The archives are MSVC-format, because that is the ABI every consumer
    links against: the Rust toolchain on Windows is MSVC-hosted, and it has
    to be, since `rusty_v8` publishes no `x86_64-pc-windows-gnu` build of V8.
    MinGW archives would not link into any of it.

    MSYS2 supplies bash, make and the POSIX tools `configure` needs. It does
    NOT supply the compiler.

    Install MSYS2 from https://www.msys2.org/, then:
        pacman -S --needed make diffutils pkgconf
    and the Visual Studio Build Tools with the VC workload.

    Output (mirrors build-ffmpeg.sh, with MSVC's names):
        .\dist\lib\avformat.lib
        .\dist\lib\avcodec.lib
        .\dist\lib\avutil.lib
        .\dist\lib\swscale.lib
        .\dist\lib\swresample.lib
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
        # MSYS, not MINGW64. What builds ffmpeg here is MSVC: MSYS2 supplies
        # the shell, make and the POSIX tools `configure` needs, and nothing
        # else. Selecting MINGW64 would put a gcc toolchain in front of the
        # compiler this build actually uses.
        $env:MSYSTEM = 'MSYS'
        # The Windows PATH reaches the shell, which is how `cl.exe` and the
        # declared `nasm` get there. Without it MSYS2 builds its own PATH from
        # /etc/profile and the compiler is simply absent.
        $env:MSYS2_PATH_TYPE = 'inherit'
        # `configure` passes Windows paths to cl.exe. MSYS2 rewrites anything
        # that looks like a POSIX path in an argument, which turns `/Fo` and
        # `-I C:\...` into something the compiler does not recognise.
        $env:MSYS2_ARG_CONV_EXCL = '*'
        & $Bash --login -c "bash '$tmpMsys'"
        if ($LASTEXITCODE -ne 0) {
            throw "MSYS2 script failed (exit $LASTEXITCODE)"
        }
    } finally {
        Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Put the MSVC toolchain into THIS process, so everything it starts has it.
#
# ffmpeg is built with cl.exe because that is the ABI the consumers link
# against: the Rust toolchain on Windows is MSVC-hosted, and it is MSVC-hosted
# because `rusty_v8` publishes no `x86_64-pc-windows-gnu` build of V8 — so a
# GNU-hosted guest cannot build anything that depends on deno_core, which on
# this workspace is the workspace's own tool.
#
# MinGW archives cannot be linked into an MSVC build, so producing them would
# make this crate unusable by every consumer that matters. `--toolchain=msvc`
# is how ffmpeg is told, and vcvars64 is how cl.exe, link.exe, lib.exe and the
# INCLUDE/LIB search paths get into the environment MSYS2 inherits.
function Import-MsvcEnvironment {
    $installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $installer)) {
        throw @'
vswhere.exe was not found, so no Visual Studio installation can be located.

ffmpeg is built here with MSVC, because the Rust toolchain that links it is
MSVC-hosted. Install the Build Tools with the VC workload:

    vs_BuildTools.exe --quiet --wait --norestart --nocache ^
        --add Microsoft.VisualStudio.Workload.VCTools ^
        --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64
'@
    }
    # The VC TOOLS component, not merely an installation: a bare Build Tools
    # install carries no compiler at all, and asking for the installation path
    # without requiring the workload finds one that cannot build anything.
    $installation = & $installer -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath 2>$null
    if ([string]::IsNullOrWhiteSpace($installation)) {
        throw ('no Visual Studio installation carries ' +
               'Microsoft.VisualStudio.Component.VC.Tools.x86.x64, so there is no ' +
               'cl.exe to build with. Install the VCTools workload.')
    }
    $vcvars = Join-Path $installation.Trim() 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path -LiteralPath $vcvars)) {
        throw "the Visual Studio at $installation has no vcvars64.bat at $vcvars"
    }
    Write-Host "    MSVC       = $installation" -ForegroundColor Green

    # `cmd /c "<bat> && set"` is the only way to read what a batch file did to
    # its environment: it exits with that environment and prints it, and this
    # process adopts what it printed.
    $exported = & cmd.exe /c "`"$vcvars`" >nul 2>&1 && set"
    if ($LASTEXITCODE -ne 0) {
        throw "vcvars64.bat failed (exit $LASTEXITCODE); the VC tools are not usable"
    }
    foreach ($line in $exported) {
        if ($line -match '^([^=]+)=(.*)$') {
            Set-Item -Path "env:$($Matches[1])" -Value $Matches[2]
        }
    }
    foreach ($needed in @('INCLUDE', 'LIB')) {
        if ([string]::IsNullOrWhiteSpace((Get-Item "env:$needed" -ErrorAction SilentlyContinue).Value)) {
            throw "vcvars64.bat ran but set no $needed; cl.exe cannot find its headers"
        }
    }
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        throw 'vcvars64.bat ran but cl.exe is still not on PATH'
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

# Everything this script produces goes under FFMPEG_BUNDLE_BUILD_DIR, and it
# has NO default — the same contract build-ffmpeg.sh carries, for the same
# reason: the one wrong answer is the source tree, and a default is how output
# ends up there. This script used to write into $Root, which put a build tree
# inside cargo's read-only git checkout of this crate.
$OutRoot = $env:FFMPEG_BUNDLE_BUILD_DIR
if ([string]::IsNullOrWhiteSpace($OutRoot)) {
    # A LITERAL here-string. The interpolating kind treats a backtick as an
    # escape, so the ``build.rs`` in the last line would have become a
    # backspace character in the middle of the message.
    throw @'
build-ffmpeg.ps1: FFMPEG_BUNDLE_BUILD_DIR is not set.

This script produces build output, and build output does not belong in a
source tree - which is the only place a default could put it. Name the
directory explicitly:

    $env:FFMPEG_BUNDLE_BUILD_DIR = 'C:\path\to\build\ffmpeg'
    .\scripts\build-ffmpeg.ps1

build.rs sets it to cargo's own build directory, so consumers never run
this by hand.
'@
}
New-Item -ItemType Directory -Force -Path $OutRoot | Out-Null

# The layout mirrors build-ffmpeg.sh exactly. build.rs publishes by renaming
# `<given>/dist` into place and knows nothing about which recipe produced it,
# so a Windows tree that spelled its directories differently would build
# successfully and then fail to publish.
$SourcesDir = Join-Path $OutRoot 'sources'
$SourceDir  = Join-Path $SourcesDir "ffmpeg-$Version"
$DistDir    = Join-Path $OutRoot 'dist'
$BuildDir   = Join-Path $OutRoot "obj\$Version"

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

MSYS2 supplies the shell, make and the POSIX tools `configure` needs. The
COMPILER is MSVC and comes from the Visual Studio Build Tools, not from here.

Install from https://www.msys2.org/, then:
    pacman -S --needed make diffutils pkgconf
"@
}
$Bash = Join-Path $Msys2Root 'usr\bin\bash.exe'
Write-Host "    MSYS2      = $Msys2Root" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Verify required tools in the shell that will run the build
# ---------------------------------------------------------------------------
Import-MsvcEnvironment

Write-Host "==> Checking build tools" -ForegroundColor Cyan
# `cl.exe` and `nasm` come from the WINDOWS side — the compiler from vcvars,
# the assembler from wherever the machine declares it — and reach the shell
# because MSYS2 inherits the Windows PATH. `make` and the POSIX tools are
# MSYS2's own. Asked for in the shell that will run the build, because that is
# the environment whose answer matters.
Invoke-Msys2Bash @'
set -euo pipefail
missing=0
for tool in cl.exe make nasm diff; do
    if command -v "$tool" >/dev/null 2>&1; then
        echo "  ok: $tool ($(command -v "$tool"))"
    else
        echo "  MISSING: $tool"
        missing=1
    fi
done
if [ "$missing" -eq 1 ]; then
    echo ""
    echo "cl.exe comes from the Visual Studio Build Tools (VC workload) and"
    echo "reaches this shell through the Windows PATH; nasm likewise."
    echo "The rest are MSYS2's:"
    echo "  pacman -S --needed make diffutils pkgconf"
    exit 1
fi
'@

# ---------------------------------------------------------------------------
# Fetch source
# ---------------------------------------------------------------------------
# Every artifact below is published by RENAME, and every guard tests the
# published name - the same rule build-ffmpeg.sh carries. A step is finished
# when its result is at its final name, and never merely because a name
# exists. Guarding on a path that is written in place makes an interrupted
# step indistinguishable from a completed one, and since every later run then
# skips it, the tree stays broken until someone deletes the right file.
if (-not (Test-Path $SourceDir)) {
    New-Item -ItemType Directory -Force -Path $SourcesDir | Out-Null

    $Tarball = Join-Path $SourcesDir "ffmpeg-$Version.tar.gz"
    if (-not (Test-Path $Tarball)) {
        # www., not the apex. The apex name has answered with a reset
        # connection for long stretches, and a build that dies there died for
        # a reason with nothing to do with this recipe.
        $Url = "https://www.ffmpeg.org/releases/ffmpeg-$VersionNoPrefix.tar.gz"
        Write-Host "==> Fetching $Url" -ForegroundColor Cyan
        $Partial = "$Tarball.partial"
        if (Test-Path $Partial) { Remove-Item -Force $Partial }
        Invoke-WebRequest -Uri $Url -OutFile $Partial -UseBasicParsing
        Move-Item -Path $Partial -Destination $Tarball
    }

    Write-Host "==> Extracting $Tarball" -ForegroundColor Cyan
    # Extracted beside the source tree and renamed in: a killed extraction
    # leaves the scratch, which the next run replaces, rather than a
    # half-populated tree sitting at the name that means "fetched".
    $Extracting = Join-Path $SourcesDir ".extracting-$Version"
    if (Test-Path $Extracting) { Remove-Item -Recurse -Force $Extracting }
    New-Item -ItemType Directory -Force -Path $Extracting | Out-Null
    # Windows 10 1803+ ships tar.exe; fall back to MSYS2 tar otherwise.
    if (Get-Command tar -CommandType Application -ErrorAction SilentlyContinue) {
        & tar -xzf $Tarball -C $Extracting
        if ($LASTEXITCODE -ne 0) { throw "tar extraction failed" }
    } else {
        $msysTar        = ConvertTo-MsysPath $Tarball
        $msysExtracting = ConvertTo-MsysPath $Extracting
        Invoke-Msys2Bash "tar -xzf '$msysTar' -C '$msysExtracting'"
    }

    # Rename from ffmpeg-X.Y to ffmpeg-nX.Y to match the pinned tag form.
    $ExtractedDir = Join-Path $Extracting "ffmpeg-$VersionNoPrefix"
    if (-not (Test-Path $ExtractedDir)) {
        throw "the tarball did not contain ffmpeg-$VersionNoPrefix"
    }
    Move-Item -Path $ExtractedDir -Destination $SourceDir
    Remove-Item -Recurse -Force $Extracting
}

# ---------------------------------------------------------------------------
# Configure + Build: MSVC's compiler, MSYS2's shell
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

$MsysSourceDir    = ConvertTo-MsysPath $SourceDir
$MsysBuildDir     = ConvertTo-MsysPath $BuildDir
$MsysDistDir      = ConvertTo-MsysPath $DistDir
$ReconfigureFlag  = if ($Reconfigure) { '1' } else { '0' }

# Feature set mirrors build-ffmpeg.sh exactly.
#
# `-MT` is the one addition: the STATIC C runtime. Every consumer of these
# archives on Windows builds with `-C target-feature=+crt-static`, because a
# cartridge that drags a VC++ runtime DLL behind it is not self-contained —
# and mixing the two CRTs is LNK4098 and a program with two heaps, which is
# worse than either. pdfium's bundle already builds `/MT` for exactly this
# reason; one runtime across the whole binary or none.
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

# Stamped after configure returns, not inferred from config.mak: configure
# writes config.mak partway through its own run and keeps going, so a
# configure killed after that point left the file behind and every later run
# skipped configuring entirely.
if [ ! -f .configured-$Version ] || [ '$ReconfigureFlag' = '1' ]; then
    echo '==> Configuring'
    rm -f .configured-$Version
    '$MsysSourceDir/configure' \
        --prefix='$MsysDistDir' \
        --arch=x86_64 \
        --target-os=win64 \
        --toolchain=msvc \
        --extra-cflags=-MT \
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
        "--enable-muxer=`$MUXERS"
    touch .configured-$Version
fi

CORES=`$(nproc 2>/dev/null || echo 4)
echo "==> Building with -j`$CORES"
make -j"`$CORES"

echo '==> Installing into $MsysDistDir'
make install

# ffmpeg names its static libraries `libavcodec.a` on every toolchain, MSVC
# included — the archives ARE MSVC-format, made by lib.exe, but the name is
# ffmpeg's own convention. `link.exe` looks for `avcodec.lib`, and so does
# rustc's `cargo:rustc-link-lib=static=avcodec`, so the names are made to say
# what the files are.
#
# Renamed rather than copied: two files holding one archive is two things to
# keep in step, and the `.a` name means "GNU archive" to everything that reads
# it.
echo '==> Naming the archives as MSVC libraries'
cd '$MsysDistDir/lib'
for archive in lib*.a; do
    [ -e "`$archive" ] || continue
    stem="`${archive#lib}"
    mv -f "`$archive" "`${stem%.a}.lib"
done
"@

Write-Host "==> Configuring and building with MSVC under MSYS2" -ForegroundColor Cyan
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
# The MSVC link line, in MSVC's own spelling. A `-l` line would describe a
# link nothing on this platform performs.
#
#   bcrypt  - avutil's CPRNG (BCryptGenRandom, in place of getrandom)
#   secur32 - SSPI, pulled in by some avformat paths
#   ws2_32  - Winsock (the pipe protocol and some demuxer paths)
$LinkFlags  = '/LIBPATH:dist\lib'
$LinkFlags += ' avformat.lib avcodec.lib swscale.lib swresample.lib avutil.lib'
$LinkFlags += ' bcrypt.lib secur32.lib ws2_32.lib'

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

$Archives = Get-ChildItem -Path (Join-Path $DistDir 'lib') -Filter '*.lib' -ErrorAction SilentlyContinue
if ($Archives) {
    $TotalMB = [math]::Round(($Archives | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
    Write-Host ("`n    Total static archive size: {0:N1} MB" -f $TotalMB) -ForegroundColor Green
}

} finally {
    Pop-Location
}
