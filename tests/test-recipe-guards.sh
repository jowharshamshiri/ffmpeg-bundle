#!/bin/bash
#
# The recipe's decisions about what has already been done.
#
# A real run of scripts/build-ffmpeg.sh downloads ffmpeg's release tarball and
# compiles it, which takes minutes; nothing here does either. What is under
# test is the set of guards that decide whether to fetch, extract and
# configure — and being interrupted part way through any of those is the
# normal case, not the exotic one, because each takes long enough to be killed
# by a closed laptop or a dropped network.
#
# TEST9705-9708.

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

# Stubs for everything the recipe shells out to. `curl` writes a real gzipped
# tar of a source tree that is empty apart from a `configure` — enough for the
# fetch and extract guards to be exercised for real rather than mocked.
make_stubs() {
    local bin="$1" log="$2"
    mkdir -p "$bin"

    # A curl that can be told to die part way, leaving whatever it had written.
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
tmp="\$(mktemp -d)"
mkdir -p "\$tmp/ffmpeg-$BARE"
printf '#!/bin/bash\nexit 0\n' > "\$tmp/ffmpeg-$BARE/configure"
chmod +x "\$tmp/ffmpeg-$BARE/configure"
tar -czf "\$out" -C "\$tmp" "ffmpeg-$BARE"
rm -rf "\$tmp"
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
    local bin="${build_dir}/.stubs"
    make_stubs "$bin" "$log"
    PATH="$bin:$PATH" FFMPEG_BUNDLE_BUILD_DIR="$build_dir" \
        bash "$ROOT/scripts/build-ffmpeg.sh" > "$out" 2>&1
}

echo "TEST9705 — a download killed part way is not cached as the tarball"
(
    work="$(scratch)"; trap 'rm -rf "$work"' EXIT
    log="$work/log"; : > "$log"
    bin="$work/build/.stubs"
    make_stubs "$bin" "$log"
    # The fetch dies with bytes already written.
    PATH="$bin:$PATH" FFMPEG_BUNDLE_BUILD_DIR="$work/build" STUB_CURL_TRUNCATE=1 \
        bash "$ROOT/scripts/build-ffmpeg.sh" > "$work/out" 2>&1 \
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

echo "TEST9708 — the release tarball is fetched from the www host"
(
    work="$(scratch)"; trap 'rm -rf "$work"' EXIT
    log="$work/log"; : > "$log"
    run_recipe "$work/build" "$log" "$work/out"
    # The apex name has answered with a reset connection for long stretches.
    # A build that dies there died for a reason with nothing to do with this
    # recipe, and the host is worth pinning so it cannot drift back.
    grep -q "https://www.ffmpeg.org/releases/ffmpeg-$BARE.tar.gz" "$log" \
        || fail "the fetch does not name www.ffmpeg.org: $(grep '^curl ' "$log")"
    exit 0
)
case_result $? "the fetch names www.ffmpeg.org, not the apex"

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
echo "${PASSED} passed, ${FAILED} failed"
[ "$FAILED" -eq 0 ]
