#!/bin/bash
#
# The recipe's decisions about what has already been done.
#
# A real run of scripts/build-ffmpeg.sh downloads ffmpeg's source and compiles
# it, which takes minutes; nothing here does either. What is under
# test is the set of guards that decide whether to fetch, extract and
# configure — and being interrupted part way through any of those is the
# normal case, not the exotic one, because each takes long enough to be killed
# by a closed laptop or a dropped network.
#
# TEST9705-9708, TEST21802-21804.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/ffmpeg-version.txt")"
BARE="${VERSION#n}"
PASSED=0
FAILED=0

# Each case runs in a subshell, so a counter it increments dies with it. The
# subshell's exit status is the result — which is why `fail` stops the case.
fail() {
    echo "  FAIL: $*" >&2
    exit 1
}

case_result() {
    if [ "$1" -eq 0 ]; then
        echo "  ok   — $2"
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
}

# The source the stub curl serves: a real gzipped tar laid out as GitHub lays
# out a tag's archive, with a source tree that is empty apart from a
# `configure`. Made ONCE, because the recipe checks a download against a
# pinned digest and a tarball made per fetch would carry a new timestamp, and
# so a new digest, every time.
FIXTURES="$(mktemp -d "${TMPDIR:-/tmp}/ffmpeg-fixtures.XXXXXX")"
trap 'rm -rf "$FIXTURES"' EXIT
make_source() {
    local into="$1" marker="$2" tree
    tree="$(mktemp -d)"
    mkdir -p "$tree/FFmpeg-$VERSION"
    printf '#!/bin/bash\n# %s\nexit 0\n' "$marker" > "$tree/FFmpeg-$VERSION/configure"
    chmod +x "$tree/FFmpeg-$VERSION/configure"
    tar -czf "$into" -C "$tree" "FFmpeg-$VERSION"
    rm -rf "$tree"
}
make_source "$FIXTURES/pinned.tar.gz" pinned
# Another archive of the same layout: what a download that is not the pinned
# source looks like.
make_source "$FIXTURES/other.tar.gz" other
digest() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}
PINNED_SHA256="$(digest "$FIXTURES/pinned.tar.gz")"

# A copy of the recipe, pinned to the fixture's digest. The recipe reads its
# pins from the directory above its own, so the copy is the recipe itself,
# checked against a source the stub can serve.
make_root() {
    local root="$1"
    mkdir -p "$root/scripts"
    cp "$ROOT/scripts/build-ffmpeg.sh" "$root/scripts/"
    cp "$ROOT/ffmpeg-version.txt" "$root/"
    printf '%s\n' "$PINNED_SHA256" > "$root/ffmpeg-source.sha256"
}

# Stubs for everything the recipe shells out to.
make_stubs() {
    local bin="$1" log="$2"
    mkdir -p "$bin"

    # A curl that serves the fixture, or can be told to die part way, leaving
    # whatever it had written, or to serve a source that is not the pinned one.
    cat > "$bin/curl" <<EOF
#!/bin/bash
echo "curl \$*" >> "$log"
out=""
while [ \$# -gt 0 ]; do
    if [ "\$1" = "-o" ]; then out="\$2"; shift; fi
    shift
done
if [ "\${STUB_CURL_TRUNCATE:-0}" = "1" ]; then
    printf 'this is not a gzip stream' > "\$out"
    exit 1
fi
if [ "\${STUB_CURL_OTHER:-0}" = "1" ]; then
    cp "$FIXTURES/other.tar.gz" "\$out"
    exit 0
fi
cp "$FIXTURES/pinned.tar.gz" "\$out"
exit 0
EOF

    # make: `make` builds, `make install` populates the prefix with the
    # archives and headers the recipe's own post-build checks look for.
    cat > "$bin/make" <<EOF
#!/bin/bash
echo "make \$*" >> "$log"
exit 0
EOF

    chmod +x "$bin"/*
}

scratch() {
    mktemp -d "${TMPDIR:-/tmp}/ffmpeg-guards.XXXXXX"
}

# Run the recipe far enough to exercise the fetch/extract/configure guards.
# It is expected to fail later, at the real build — that part is not what
# these cases are about, and stubbing a complete ffmpeg install would assert
# nothing about the guards.
run_recipe() {
    local build_dir="$1" log="$2" out="$3"
    local bin="${build_dir}/.stubs" root="${build_dir}/.recipe"
    make_stubs "$bin" "$log"
    make_root "$root"
    PATH="$bin:$PATH" FFMPEG_BUNDLE_BUILD_DIR="$build_dir" \
        bash "$root/scripts/build-ffmpeg.sh" > "$out" 2>&1
}

echo "TEST9705 — a download killed part way is not cached as the tarball"
(
    work="$(scratch)"; trap 'rm -rf "$work"' EXIT
    log="$work/log"; : > "$log"
    # The fetch dies with bytes already written.
    STUB_CURL_TRUNCATE=1 run_recipe "$work/build" "$log" "$work/out" \
        && fail "a failed download reported success"

    tarball="$work/build/sources/ffmpeg-$VERSION.tar.gz"
    [ -f "$tarball" ] && fail "a truncated download was left at the name that means 'fetched'"

    # And the next run fetches again rather than trying to extract the rubble.
    : > "$log"
    run_recipe "$work/build" "$log" "$work/out"
    grep -q "^curl " "$log" || fail "the second run did not re-fetch"
    [ -x "$work/build/sources/ffmpeg-$VERSION/configure" ] \
        || fail "the source tree was not extracted on the second run"
    exit 0
)
case_result $? "a truncated tarball never reaches its final name, so the next run refetches"

echo "TEST9706 — an extraction killed part way leaves no source tree"
(
    work="$(scratch)"; trap 'rm -rf "$work"' EXIT
    log="$work/log"; : > "$log"
    mkdir -p "$work/build/sources"
    # What a killed `tar` leaves: the tarball complete, and a partial tree.
    # It must not be sitting at the name that means "extracted".
    printf 'not a gzip stream' > "$work/build/sources/ffmpeg-$VERSION.tar.gz"
    run_recipe "$work/build" "$log" "$work/out"
    if [ -d "$work/build/sources/ffmpeg-$VERSION" ]; then
        fail "a failed extraction published a source tree"
    fi
    exit 0
)
case_result $? "a failed extraction publishes nothing at the source-tree name"

echo "TEST9707 — configure is stamped by us, not inferred from config.mak"
(
    work="$(scratch)"; trap 'rm -rf "$work"' EXIT
    log="$work/log"; : > "$log"
    run_recipe "$work/build" "$log" "$work/out"
    stamp="$work/build/obj/$VERSION/.configured-$VERSION"
    [ -f "$stamp" ] || fail "no stamp was written after configure returned"

    # What an interrupted configure leaves: config.mak, written partway
    # through its own run. The old guard read that as "already configured".
    rm -f "$stamp"
    : > "$work/build/obj/$VERSION/config.mak"
    : > "$log"
    run_recipe "$work/build" "$log" "$work/out"
    grep -q "Configuring" "$work/out" || fail "configure was skipped because config.mak existed"
    exit 0
)
case_result $? "a config.mak with no stamp means configure runs again"

echo "TEST9708 — the source is GitHub's archive of the pinned tag"
(
    work="$(scratch)"; trap 'rm -rf "$work"' EXIT
    log="$work/log"; : > "$log"
    run_recipe "$work/build" "$log" "$work/out"
    # ffmpeg.org's one server has answered with resets and timeouts for long
    # stretches, first at the apex name and then at www. A build that dies
    # there died for a reason with nothing to do with this recipe, so the
    # source comes from where the tag is mirrored, and cannot drift back.
    grep -q "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/$VERSION.tar.gz" "$log" \
        || fail "the fetch does not name GitHub's archive of $VERSION: $(grep '^curl ' "$log")"
    grep -q "ffmpeg.org" "$log" && fail "the fetch still reaches ffmpeg.org: $(grep '^curl ' "$log")"
    exit 0
)
case_result $? "the fetch names GitHub's archive of the pinned tag, never ffmpeg.org"

echo "TEST21802 — a download that is not the pinned source is refused"
(
    work="$(scratch)"; trap 'rm -rf "$work"' EXIT
    log="$work/log"; : > "$log"
    STUB_CURL_OTHER=1 run_recipe "$work/build" "$log" "$work/out" \
        && fail "a source with another digest was built"
    other="$(digest "$FIXTURES/other.tar.gz")"
    grep -q "its SHA-256 is $other, and ffmpeg-source.sha256 pins $PINNED_SHA256" "$work/out" \
        || fail "the refusal does not name both digests: $(tail -3 "$work/out")"
    sources="$work/build/sources"
    [ -e "$sources/ffmpeg-$VERSION.tar.gz" ] && fail "the refused download was published as the tarball"
    [ -e "$sources/ffmpeg-$VERSION.tar.gz.partial" ] && fail "the refused download was left behind"
    [ -e "$sources/ffmpeg-$VERSION" ] && fail "a source tree was extracted from the refused download"
    grep -q "Configuring" "$work/out" && fail "configure ran on a source that was refused"

    # And the next run fetches again, and builds from the pinned source.
    : > "$log"
    run_recipe "$work/build" "$log" "$work/out"
    grep -q "^curl " "$log" || fail "the run after a refusal did not fetch again"
    grep -q "# pinned" "$sources/ffmpeg-$VERSION/configure" \
        || fail "the run after a refusal did not extract the pinned source"
    exit 0
)
case_result $? "a source whose digest is not the pinned one is never published, extracted or built"

echo "TEST21803 — the source tree names its release, as the release tarball does"
(
    work="$(scratch)"; trap 'rm -rf "$work"' EXIT
    log="$work/log"; : > "$log"
    run_recipe "$work/build" "$log" "$work/out"
    tree="$work/build/sources/ffmpeg-$VERSION"
    [ -x "$tree/configure" ] || fail "the source tree was not published at ffmpeg-$VERSION"
    # The release tarball's VERSION is the bare version and a newline. Without
    # it, ffmpeg's version.sh asks git, which in a consumer's checkout answers
    # with the consumer's tag.
    [ "$(od -An -c "$tree/VERSION" 2>/dev/null | tr -s ' ')" = "$(printf '%s\n' "$BARE" | od -An -c | tr -s ' ')" ] \
        || fail "VERSION is not '$BARE' and a newline: $(od -An -c "$tree/VERSION" 2>&1)"
    exit 0
)
case_result $? "the extracted tree carries VERSION, so ffmpeg names the pinned release"

echo "TEST9709 — the MSVC recipe compiles as C11, so <stdatomic.h> is usable"
(
    ps1="$ROOT/scripts/build-ffmpeg.ps1"
    [ -f "$ps1" ] || fail "the Windows recipe is missing at $ps1"

    # ffmpeg 7.x includes <stdatomic.h>. MSVC's vcruntime_c11_stdatomic.h is
    # `#error "C atomic support is not enabled"` unless the unit is compiled as
    # C11, so a configure that omits it fails `check_builtin stdatomic` and the
    # build dies on the first file that pulls the header in — behind a wall of
    # C1083 "cannot open libavutil/..." errors that name the wrong problem.
    #
    # It must be the --stdc OPTION, not a cflag. configure defaults to
    # stdc_default="c17" and appends its own -std after --extra-cflags, so the
    # cflag spelling loses to `warning D9025: overriding '/std:c11' with
    # '/std:c17'` on every file. Asserting the option is what distinguishes
    # the fix that works from the one that looks right and compiles as C17.
    #
    # Read off the recipe rather than a real build: configuring ffmpeg with
    # MSVC takes minutes and needs Windows, and the decision under test is one
    # line of the recipe.
    # The configure ARGUMENT, not the prose about it: a line that is passed to
    # configure is indented and ends in a backslash continuation, while the
    # comment above it says `--stdc=c11` too. Matching anywhere in the file let
    # the flag be deleted with the comment left behind and this still passed.
    grep -qE '^[[:space:]]+--stdc=c11[[:space:]]*\\' "$ps1" \
        || fail "the MSVC recipe does not pass --stdc=c11 to configure; ffmpeg's \
<stdatomic.h> will not compile under MSVC, and an -std:c11 in --extra-cflags is \
overridden by configure's own c17 default"

    # A cflag spelling of the STANDARD is the mistake this guards against: it
    # is silently overridden, so a recipe carrying only that is not C11.
    cflags="$(grep -o -- '--extra-cflags=[^\\"]*' "$ps1" | head -1)"
    [ -n "$cflags" ] || fail "the MSVC recipe passes no --extra-cflags at all"
    case "$cflags" in
        *-std:c11*) fail "the MSVC recipe sets -std:c11 through --extra-cflags, \
which configure's c17 default overrides; --stdc=c11 is the setting that holds" ;;
    esac

    # C11 mode is not enough on its own. MSVC keeps defining __STDC_NO_ATOMICS__
    # until atomics are opted into separately, and that is the FIRST of the two
    # #errors in vcruntime_c11_stdatomic.h — so --stdc=c11 alone still failed.
    # It belongs in the cflags: not being a -std flag is what keeps configure
    # from overriding it.
    case "$cflags" in
        *-experimental:c11atomics*) : ;;
        *) fail "the MSVC recipe does not enable C11 atomics ($cflags); MSVC \
defines __STDC_NO_ATOMICS__ without -experimental:c11atomics and <stdatomic.h> \
refuses to compile even in C11 mode" ;;
    esac

    # -MT selects the static runtime, and losing it while moving the standard
    # would trade one broken link for another.
    case "$cflags" in
        *-MT*) : ;;
        *) fail "the MSVC recipe no longer selects the static runtime ($cflags)" ;;
    esac
    exit 0
)
case_result $? "the MSVC configure asks for C11, which is what makes stdatomic.h compile"

echo "TEST9710 — the MSVC recipe converts the paths it hands cl.exe"
(
    ps1="$ROOT/scripts/build-ffmpeg.ps1"
    [ -f "$ps1" ] || fail "the Windows recipe is missing at $ps1"

    excl=$(grep -o "MSYS2_ARG_CONV_EXCL = '[^']*'" "$ps1" | head -1)
    [ -n "$excl" ] || fail "the MSVC recipe sets no MSYS2_ARG_CONV_EXCL at all"

    # `*` excludes everything, so make's source paths reach cl.exe as
    # `/c/ProgramData/...` and it reads the leading slash as an option:
    # "D9002: ignoring unknown option" for every file, and nothing compiled.
    case "$excl" in
        *"'*'"*|*';*;'*|*"='*"*) fail "MSYS2_ARG_CONV_EXCL excludes everything ($excl); \
no path is converted and cl.exe is handed POSIX paths it cannot resolve" ;;
    esac

    # A bare `-` is the same mistake one level down: ffmpeg's include flags
    # are GNU-spelled and carry the path INLINE. common.mak builds
    # `IFLAGS := -I. -I$(SRC_LINK)/`, so excluding `-` hands cl.exe
    # `-I/c/ProgramData/...` and every source fails to find libavutil/*.h --
    # a wall of C1083 that reads like a broken checkout.
    case ";$excl;" in
        *";-;"*|*"';-'"*) fail "MSYS2_ARG_CONV_EXCL excludes every GNU-spelled \
argument ($excl); ffmpeg's -I flags carry their path inline and would not be \
converted" ;;
    esac
    printf '%s' "$excl" | grep -qE "(^|;)/I(;|')" \
        && fail "MSYS2_ARG_CONV_EXCL excludes /I ($excl); an include path that \
is not converted is one cl.exe cannot open"

    # And the switches that are never paths must still be excluded, or `/MT`
    # becomes a path to a directory that does not exist.
    for switch in /Fo /D /nologo /link; do
        printf '%s' "$excl" | grep -q -- "$switch" \
            || fail "MSYS2_ARG_CONV_EXCL no longer excludes $switch ($excl); \
converting a switch that is not a path breaks the compile another way"
    done
    exit 0
)
case_result $? "only arguments that carry paths are left for MSYS2 to convert"

echo
echo "TEST9711 — every platform's recipe builds the capture backend"
(
    ps1="$ROOT/scripts/build-ffmpeg.ps1"
    sh="$ROOT/scripts/build-ffmpeg.sh"
    [ -f "$ps1" ] && [ -f "$sh" ] || fail "a recipe is missing"

    # build.rs links avdevice unconditionally, and capture -- microphones and
    # cameras -- is part of what this crate delivers. A platform that disables
    # it ships a dist the crate cannot link, which is how a perfectly compiled
    # Windows build ended on "avdevice.lib is missing after a successful
    # build". Dropping avdevice from the list would have made the message go
    # away by making the gap permanent.
    # The configure ARGUMENTS, not the prose about them: a comment explaining
    # why avdevice is enabled says `--disable-avdevice` too, and matching
    # anywhere in the file would read that as the flag.
    grep -qE '^[[:space:]]+--enable-avdevice' "$sh" \
        || fail "the POSIX recipe no longer enables avdevice; build.rs links it"
    grep -qE '^[[:space:]]+--enable-avdevice' "$ps1" \
        || fail "the MSVC recipe no longer enables avdevice; build.rs links it"
    grep -qE '^[[:space:]]+--disable-avdevice' "$ps1" \
        && fail "the MSVC recipe disables avdevice while build.rs links it: \
that dist cannot be linked, and Windows would ship with no capture at all"

    # An indev per platform, because avdevice with no input device opens
    # nothing. dshow is the Windows equivalent of alsa/v4l2 and avfoundation.
    grep -qE '^[[:space:]]+--enable-indev=dshow' "$ps1" \
        || fail "the MSVC recipe enables avdevice but no input device, so it \
can open neither a microphone nor a camera"
    grep -qE -- "--enable-indev=(alsa|avfoundation)" "$sh" \
        || fail "the POSIX recipe enables avdevice but no input device"

    # And the request is VERIFIED. configure drops an indev whose dependencies
    # it cannot find and says so only in config.log, so a build can report
    # success and ship a libavdevice that opens nothing.
    grep -q "CONFIG_DSHOW_INDEV=yes" "$ps1" \
        || fail "the MSVC recipe does not check that configure kept dshow; \
--enable-indev is a request, and a dropped one is silent"

    # And the check must use tools the guest HAS. MSYS2 ships no binutils, so
    # `ar`, `nm` and `strings` are all absent there: the members check died on
    # "ar: command not found" and reported capture as missing when it was
    # built. A verification that cannot run is worse than none, because it
    # fails the build for the thing it was meant to confirm.
    for absent in "ar " "nm " "strings "; do
        grep -qE "^[[:space:]]*(if !? ?)?$absent" "$ps1" \
            && fail "the MSVC recipe runs \`$absent\` — MSYS2 has no binutils, \
so that check cannot run on the guest it is checking"
    done
    exit 0
)
case_result $? "avdevice and an input device are built on every platform, and checked"

echo
echo "TEST9712 — the bash the MSVC recipe generates has no PowerShell escapes in it"
(
    ps1="$ROOT/scripts/build-ffmpeg.ps1"
    [ -f "$ps1" ] || fail "the MSVC recipe is missing"
    stray=$(mktemp)
    trap 'rm -f "$stray"' EXIT

    # $BuildScript is an INTERPOLATING here-string: PowerShell reads every
    # character of it before bash ever does, and the backtick is PowerShell
    # escape character. So a backtick in that block is not punctuation, it is
    # an instruction to drop the next character.
    #
    # Prose is where this bites, because prose is where nobody is thinking
    # about the shell. The word nm written between backticks reached bash as
    # nm with the n eaten; bash ran what was left and the whole ffmpeg build
    # died on "line 131: m: command not found", pointing at a COMMENT. Two
    # suites failed for an hour on a message about a file that was fine.
    #
    # `$ is the one legitimate use: it escapes the dollar so a bash variable
    # survives interpolation. Everything else is refused.
    awk '
        /^\$BuildScript = @"$/ { inside = 1; next }
        inside && /^"@$/       { inside = 0 }
        inside {
            line = $0
            n = 0
            while ((i = index(line, "`")) > 0) {
                rest = substr(line, i + 1, 1)
                if (rest != "$") { n++ }
                line = substr(line, i + 2)
            }
            if (n > 0) { print NR ": " $0 }
        }
    ' "$ps1" > "$stray"

    if [ -s "$stray" ]; then
        while IFS= read -r offending; do
            echo "        $offending"
        done < "$stray"
        fail "the generated bash carries PowerShell escapes: each backtick above \
eats the character after it before bash sees the line"
    fi
    exit 0
)
case_result $? "the generated bash carries no PowerShell escapes"

echo
echo "TEST12104 — the MSVC recipe extracts with Windows' own tar, named by path"
(
    ps1="$ROOT/scripts/build-ffmpeg.ps1"
    [ -f "$ps1" ] || fail "the MSVC recipe is missing"

    # Asking for `tar` on PATH gets GNU tar whenever the build is started from
    # an MSYS2 shell, and GNU tar reads `C:\...` as a remote HOST:PATH:
    #   tar (child): Cannot connect to C: resolve failed
    # on a tarball that was on the local disk (capdag CLI stubs, pve Windows
    # guest). Windows' bsdtar takes a drive letter as a drive letter.
    grep -qF "Join-Path \$env:SystemRoot 'System32\\tar.exe'" "$ps1" \
        || fail "the recipe does not name Windows' own tar.exe by its path"
    if grep -qE "^[[:space:]]*& tar " "$ps1"; then
        fail "the recipe still runs whichever 'tar' is first on PATH"
    fi
    exit 0
)
case_result $? "the MSVC recipe extracts with Windows' own tar"

echo
echo "TEST21804 — the MSVC recipe fetches the pinned source as the POSIX one does"
(
    ps1="$ROOT/scripts/build-ffmpeg.ps1"
    [ -f "$ps1" ] || fail "the MSVC recipe is missing"

    # Read off the recipe: it cannot run here, because it checks for MSVC and
    # MSYS2 before it fetches anything.
    grep -qE '^[[:space:]]+\$Url = "https://github\.com/FFmpeg/FFmpeg/archive/refs/tags/\$Version\.tar\.gz"' "$ps1" \
        || fail "the MSVC recipe does not fetch GitHub's archive of the pinned tag"
    grep -qE '^[^#]*ffmpeg\.org' "$ps1" && fail "the MSVC recipe still reaches ffmpeg.org"

    # The pin is the same file the POSIX recipe reads, and the download is
    # checked against it BEFORE it reaches the name that means "fetched".
    grep -qF "Join-Path \$Root 'ffmpeg-source.sha256'" "$ps1" \
        || fail "the MSVC recipe does not read its pin from ffmpeg-source.sha256"
    check=$(grep -nE '^[[:space:]]+if \(\$ActualSha256 -cne \$ExpectedSha256\)' "$ps1" | head -1 | cut -d: -f1)
    publish=$(grep -nF 'Move-Item -Path $Partial -Destination $Tarball' "$ps1" | head -1 | cut -d: -f1)
    [ -n "$check" ] || fail "the MSVC recipe does not compare the download's digest with the pin"
    [ -n "$publish" ] || fail "the MSVC recipe does not publish the tarball by rename"
    [ "$check" -lt "$publish" ] || fail "the MSVC recipe publishes the tarball before checking its digest"
    grep -qE 'Get-FileHash -Algorithm SHA256 -LiteralPath \$Partial' "$ps1" \
        || fail "the digest compared is not the downloaded file's"

    # And the tree is named by its release before it is published.
    version=$(grep -nE "^[[:space:]]+\\[System\\.IO\\.File\\]::WriteAllText\(\(Join-Path \\\$ExtractedDir 'VERSION'\), \"\\\$VersionNoPrefix\`n\"" "$ps1" | head -1 | cut -d: -f1)
    moved=$(grep -nF 'Move-Item -Path $ExtractedDir -Destination $SourceDir' "$ps1" | head -1 | cut -d: -f1)
    [ -n "$version" ] || fail "the MSVC recipe does not write VERSION into the extracted tree"
    [ -n "$moved" ] && [ "$version" -lt "$moved" ] \
        || fail "the MSVC recipe publishes the source tree before writing VERSION"
    grep -qF '$ExtractedDir = Join-Path $Extracting "FFmpeg-$Version"' "$ps1" \
        || fail "the MSVC recipe does not look for the archive's FFmpeg-<tag> directory"
    exit 0
)
case_result $? "the MSVC recipe fetches, checks and names the source as the POSIX one does"

echo
echo "${PASSED} passed, ${FAILED} failed"
[ "$FAILED" -eq 0 ]
