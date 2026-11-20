#!/bin/bash
#
# The build lock: one build of ffmpeg at a time for one identity, and no
# build kept waiting by one that is gone.
#
# Each case runs real cargo builds of copies of this crate, in their own
# target directories and sharing one FFMPEG_BUNDLE_BUILD_DIR, as a workspace
# test run does. The copies' recipe is a stub: what is under test is build.rs's
# lock, and a real recipe would only add a quarter of an hour of compiling
# around it. The stub says when it has started, under which build process,
# then does what the case tells it: fail at once, wait to be told to go on,
# or kill the build that started it.
#
# The test signals no process in a passing run. A holder that is killed is
# killed by its own recipe, which ends its build's build-script process (its
# parent), and then itself. A build still running when its case gives up on
# it is ended by the id of the process the test started. On Linux each build
# runs in a pid namespace of its own, whose first process is that one, so
# ending it ends every process of that build and nothing else; cargo is a
# wrapper that starts another cargo, and ending the wrapper alone would leave
# the build running.
#
# Runs on Linux and macOS with bash, and on Windows from MSYS2's bash, where
# the build script runs the PowerShell recipe.
#
# TEST21902-21905.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASSED=0
FAILED=0

# How long a build that is free to take the lock may take to start its
# recipe: the build script is compiled before the case begins, so this is
# cargo's own start and the lock, and it is seconds.
PROMPT_SECONDS=20
# How long a build waiting on a live holder is watched to see that it waits.
WAIT_SECONDS=8

case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) WINDOWS=1 ;;
    *) WINDOWS=0 ;;
esac

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

# A path as the build script and the PowerShell recipe read it.
native() {
    if [ "$WINDOWS" = 1 ]; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# The stub recipes. Both are written into every copy, because build.rs hashes
# this platform's recipe into the build identity, and the copies must agree on
# it to share one lock.
#
# Each writes `<name>.started` holding the process id of the build that ran
# it (its parent), and then:
#   fail   — exits 1 at once: the build took the lock and ran its recipe.
#   die    — waits for `<name>.go`, then kills its build and itself.
#   orphan — waits for `<name>.go`, kills its build, then goes on running
#            until `<name>.finish` appears, and writes `<name>.finished`.
write_stubs() {
    local scripts="$1"
    mkdir -p "$scripts"
    cat > "$scripts/build-ffmpeg.sh" <<'EOF'
#!/bin/bash
dir="$LOCK_TEST_DIR"; name="$LOCK_TEST_NAME"
until_exists() { while [ ! -e "$1" ]; do sleep 0.1; done; }
build=$PPID
printf '%s\n' "$build" > "$dir/$name.started.partial"
mv "$dir/$name.started.partial" "$dir/$name.started"
case "$LOCK_TEST_MODE" in
    fail) echo "stub recipe: failing as asked" >&2; exit 1 ;;
    die) until_exists "$dir/$name.go"; kill -KILL "$build"; kill -KILL $$ ;;
    orphan)
        until_exists "$dir/$name.go"
        kill -KILL "$build"
        until_exists "$dir/$name.finish"
        : > "$dir/$name.finished"
        exit 0
        ;;
esac
echo "stub recipe: unknown LOCK_TEST_MODE '$LOCK_TEST_MODE'" >&2
exit 2
EOF
    cat > "$scripts/build-ffmpeg.ps1" <<'EOF'
$ErrorActionPreference = 'Stop'
$dir = $env:LOCK_TEST_DIR; $name = $env:LOCK_TEST_NAME
function Wait-Exists($path) { while (-not (Test-Path -LiteralPath $path)) { Start-Sleep -Milliseconds 100 } }
$build = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
Set-Content -LiteralPath (Join-Path $dir "$name.started.partial") -Value $build -NoNewline
Move-Item -LiteralPath (Join-Path $dir "$name.started.partial") -Destination (Join-Path $dir "$name.started")
switch ($env:LOCK_TEST_MODE) {
    'fail' { [Console]::Error.WriteLine('stub recipe: failing as asked'); exit 1 }
    'die' {
        Wait-Exists (Join-Path $dir "$name.go")
        Stop-Process -Id $build -Force
        Stop-Process -Id $PID -Force
    }
    'orphan' {
        Wait-Exists (Join-Path $dir "$name.go")
        Stop-Process -Id $build -Force
        Wait-Exists (Join-Path $dir "$name.finish")
        Set-Content -LiteralPath (Join-Path $dir "$name.finished") -Value ''
        exit 0
    }
}
[Console]::Error.WriteLine("stub recipe: unknown LOCK_TEST_MODE '$($env:LOCK_TEST_MODE)'")
exit 2
EOF
    chmod +x "$scripts/build-ffmpeg.sh"
}

# A copy of this crate, with the stub recipes.
make_copy() {
    local copy="$1"
    mkdir -p "$copy"
    cp "$ROOT/Cargo.toml" "$ROOT/Cargo.lock" "$ROOT/build.rs" \
        "$ROOT/ffmpeg-version.txt" "$ROOT/ffmpeg-source.sha256" "$copy/"
    cp -R "$ROOT/src" "$copy/src"
    write_stubs "$copy/scripts"
}

# Start a build of the copy NAME, whose recipe runs in MODE, in the
# background. Its process id is in BUILD_PID.
start_build() {
    local work="$1" name="$2" mode="$3"
    LOCK_TEST_DIR="$(native "$work/signals")" LOCK_TEST_NAME="$name" LOCK_TEST_MODE="$mode" \
        FFMPEG_BUNDLE_BUILD_DIR="$(native "$work/root")" \
        ${LAUNCH[@]+"${LAUNCH[@]}"} cargo build --manifest-path "$(native "$work/$name/Cargo.toml")" \
        > "$work/$name.log" 2>&1 &
    BUILD_PID=$!
}

# What a build is started under. On Linux, a pid namespace of its own: the
# process the test starts is `unshare`, which ends the namespace's first
# process, and with it every process in the namespace, when it is ended.
#
# That first process runs cargo, and then, for a build whose recipe is to
# outlive it, waits for the recipe to say it has finished: the namespace ends
# with its first process, and would take the recipe with it.
LAUNCH=()
if [ "$(uname -s)" = Linux ]; then
    command -v unshare > /dev/null \
        || { echo "unshare (util-linux) is required to run these cases on Linux" >&2; exit 1; }
    LAUNCH=(unshare --pid --fork --kill-child)
    [ "$(id -u)" = 0 ] || LAUNCH+=(--user --map-current-user)
    LAUNCH+=(bash -c '
        "$@"; status=$?
        if [ "$LOCK_TEST_MODE" = orphan ]; then
            while [ ! -e "$LOCK_TEST_DIR/$LOCK_TEST_NAME.finished" ]; do sleep 0.1; done
        fi
        exit $status
    ' build)
fi

# Wait up to SECONDS for PATH to exist. Prints how many tenths it took.
await() {
    local path="$1" seconds="$2" tenths=0
    while [ ! -e "$path" ]; do
        [ "$tenths" -ge $((seconds * 10)) ] && return 1
        sleep 0.1
        tenths=$((tenths + 1))
    done
    echo "$tenths"
}

# A case's directory, with copies a and b, and each compiled once.
#
# The first build of each takes the free lock and runs its recipe, which
# fails. That proves a free lock is taken at once, and leaves the build
# script compiled, so that in the case itself a build reaches the lock within
# a second of starting.
prepare() {
    local work="$1" name pid
    mkdir -p "$work/signals" "$work/root"
    for name in a b; do
        make_copy "$work/$name"
        start_build "$work" "$name" fail
        pid=$BUILD_PID
        wait "$pid" && fail "the first build of $name succeeded with a recipe that fails"
        [ -e "$work/signals/$name.started" ] || {
            cat "$work/$name.log" >&2
            fail "the first build of $name did not run its recipe"
        }
        rm -f "$work/signals/$name.started"
        mv "$work/$name.log" "$work/$name.first.log"
    done
    # A holder that failed left no record of itself.
    if ls "$work/root"/*.owner > /dev/null 2>&1; then
        fail "a build whose recipe failed left an owner record: $(cat "$work/root"/*.owner)"
    fi
}

# End the case's builds: let a holder still waiting go, and wait for every
# build it started. A build still running past its deadline is killed by the
# id of the process this test started for it, and nothing else.
finish_case() {
    local work="$1"; shift
    : > "$work/signals/a.go"
    : > "$work/signals/a.finish"
    local pid
    for pid in "$@"; do
        local tenths=0
        while kill -0 "$pid" 2> /dev/null && [ "$tenths" -lt $((PROMPT_SECONDS * 10)) ]; do
            sleep 0.1
            tenths=$((tenths + 1))
        done
        if kill -0 "$pid" 2> /dev/null; then
            echo "  note: build $pid did not end; killing it" >&2
            kill -KILL "$pid" 2> /dev/null
        fi
        wait "$pid" 2> /dev/null
    done
}

scratch() {
    mktemp -d "${TMPDIR:-/tmp}/ffmpeg-lock.XXXXXX"
}

echo "TEST21902 — the lock records the build that holds it"
(
    work="$(scratch)"; trap 'rm -rf "$work"' EXIT
    prepare "$work"
    start_build "$work" a die
    a=$BUILD_PID
    await "$work/signals/a.started" "$PROMPT_SECONDS" > /dev/null \
        || { finish_case "$work" "$a"; cat "$work/a.log" >&2; fail "a did not start its recipe"; }
    holder="$(tr -d '[:space:]' < "$work/signals/a.started")"
    record="$(cat "$work/root"/*.owner 2> /dev/null)"
    finish_case "$work" "$a"
    [ -n "$record" ] || fail "no owner record beside the lock while a build held it"
    printf '%s\n' "$record" | grep -qx "pid=$holder" \
        || fail "the record does not name the holder's process ($holder): $record"
    printf '%s\n' "$record" | grep -qix "host=$(hostname)" \
        || fail "the record does not name this machine ($(hostname)): $record"
    printf '%s\n' "$record" | grep -qE '^started=[0-9]+$' \
        || fail "the record does not say when the lock was taken: $record"
    exit 0
)
case_result $? "the owner record names the holder's process, its machine and when it took the lock"

echo "TEST21903 — a live holder makes a second build wait"
(
    work="$(scratch)"; trap 'rm -rf "$work"' EXIT
    prepare "$work"
    start_build "$work" a die
    a=$BUILD_PID
    await "$work/signals/a.started" "$PROMPT_SECONDS" > /dev/null \
        || { finish_case "$work" "$a"; cat "$work/a.log" >&2; fail "a did not start its recipe"; }
    start_build "$work" b fail
    b=$BUILD_PID
    if await "$work/signals/b.started" "$WAIT_SECONDS" > /dev/null; then
        finish_case "$work" "$a" "$b"
        fail "b ran its recipe while a held the lock"
    fi
    kill -0 "$b" 2> /dev/null || { finish_case "$work" "$a" "$b"; cat "$work/b.log" >&2; fail "b ended instead of waiting"; }
    finish_case "$work" "$a" "$b"
    exit 0
)
case_result $? "a build arriving while another builds waits for it, and runs no recipe"

echo "TEST21904 — a killed holder's lock is taken over at once"
(
    work="$(scratch)"; trap 'rm -rf "$work"' EXIT
    prepare "$work"
    start_build "$work" a die
    a=$BUILD_PID
    await "$work/signals/a.started" "$PROMPT_SECONDS" > /dev/null \
        || { finish_case "$work" "$a"; cat "$work/a.log" >&2; fail "a did not start its recipe"; }
    holder="$(tr -d '[:space:]' < "$work/signals/a.started")"
    start_build "$work" b fail
    b=$BUILD_PID
    # b is waiting on a. Now a's recipe kills a's build, and itself.
    sleep 2
    : > "$work/signals/a.go"
    tenths="$(await "$work/signals/b.started" "$PROMPT_SECONDS")" || {
        finish_case "$work" "$a" "$b"
        cat "$work/b.log" >&2
        fail "b did not take the lock over within ${PROMPT_SECONDS}s of a being killed"
    }
    echo "  b took the lock over $((tenths / 10)).$((tenths % 10))s after a was killed"
    finish_case "$work" "$a" "$b"
    grep -q "pid=$holder host=.*ended without finishing" "$work/b.log" \
        || { cat "$work/b.log" >&2; fail "b did not say whose lock it took over"; }
    exit 0
)
case_result $? "a build waiting on a holder that is killed runs its recipe within seconds, naming it"

echo "TEST21905 — a holder's recipe holds the lock until it ends"
(
    work="$(scratch)"; trap 'rm -rf "$work"' EXIT
    prepare "$work"
    start_build "$work" a orphan
    a=$BUILD_PID
    await "$work/signals/a.started" "$PROMPT_SECONDS" > /dev/null \
        || { finish_case "$work" "$a"; cat "$work/a.log" >&2; fail "a did not start its recipe"; }
    start_build "$work" b fail
    b=$BUILD_PID
    sleep 2
    # a's recipe kills a's build and goes on running.
    : > "$work/signals/a.go"
    if [ "$WINDOWS" = 1 ]; then
        # Windows: the recipe ends with the build that started it, so b takes
        # the lock over at once, and the recipe never finishes.
        await "$work/signals/b.started" "$PROMPT_SECONDS" > /dev/null || {
            finish_case "$work" "$a" "$b"; cat "$work/b.log" >&2
            fail "b did not take the lock over when a and its recipe were ended"
        }
        [ -e "$work/signals/a.finished" ] && fail "a's recipe outlived the build that started it"
    else
        # Unix: the recipe holds the lock until it ends, so b waits for it.
        if await "$work/signals/b.started" "$WAIT_SECONDS" > /dev/null; then
            finish_case "$work" "$a" "$b"
            fail "b ran its recipe while a's recipe was still running"
        fi
        : > "$work/signals/a.finish"
        await "$work/signals/a.finished" "$PROMPT_SECONDS" > /dev/null \
            || { finish_case "$work" "$a" "$b"; fail "a's recipe did not finish when told"; }
        await "$work/signals/b.started" "$PROMPT_SECONDS" > /dev/null || {
            finish_case "$work" "$a" "$b"; cat "$work/b.log" >&2
            fail "b did not take the lock over when a's recipe ended"
        }
    fi
    finish_case "$work" "$a" "$b"
    exit 0
)
case_result $? "no second recipe runs while a killed build's recipe still does"

echo
echo "${PASSED} passed, ${FAILED} failed"
[ "$FAILED" -eq 0 ]
