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

echo
echo "${PASSED} passed, ${FAILED} failed"
[ "$FAILED" -eq 0 ]
