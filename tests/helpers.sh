#!/bin/bash
# Test helpers: sandbox creation, fixtures, stubs, assertions.
# Every test runs inside a mktemp sandbox. Nothing here may touch the real ~/.pi.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_HOME="${HOME:-}"
ORIG_TMPDIR="${TMPDIR:-/tmp}"
FAILS=0
PASSES=0
SANDBOX=""

# ── Flavors ────────────────────────────────────────────────────
# Each test is run once per available flavor (bash, pwsh).
HAVE_PWSH=0; command -v pwsh >/dev/null 2>&1 && HAVE_PWSH=1
FLAVORS=(sh); [[ "$HAVE_PWSH" == 1 ]] && FLAVORS+=(ps1)
if [[ -n "${TEST_FLAVORS:-}" ]]; then read -ra FLAVORS <<<"$TEST_FLAVORS"; fi

# run_script <flavor> <name> [args...]   name = backup-pi | restore-pi | pi-clean-reinstall
run_script() {
  local flavor="$1" name="$2"; shift 2
  assert_in_sandbox
  if [[ "$flavor" == sh ]]; then
    bash "$REPO_ROOT/$name.sh" "$@"
  else
    pwsh -NoProfile -ExecutionPolicy Bypass -File "$REPO_ROOT/$name.ps1" "$@"
  fi
}

# ── Sandbox ────────────────────────────────────────────────────
sandbox_new() {
  # Create under the ORIGINAL temp dir (TMPDIR is rewritten into each sandbox).
  : "${ORIG_TMPDIR:=${TMPDIR:-/tmp}}"
  [[ -d "$ORIG_TMPDIR" ]] || { echo "FATAL: base temp dir missing: $ORIG_TMPDIR" >&2; exit 99; }
  local base
  base="$(mktemp -d "${ORIG_TMPDIR%/}/pi-backup-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 99; }
  [[ -d "$base" ]] || { echo "FATAL: sandbox not created" >&2; exit 99; }
  SANDBOX="$(cd "$base" && pwd -P)"
  case "$SANDBOX" in */pi-backup-test.*) ;; *) echo "FATAL: unexpected sandbox path $SANDBOX" >&2; exit 99 ;; esac
  export HOME="$SANDBOX/home"
  export USERPROFILE="$HOME"
  export PI_ROOT="$HOME/.pi"
  export BACKUP_ROOT="$SANDBOX/backups"
  export LOCAL_EXT_ROOT="$SANDBOX/projects"
  export TMPDIR="$SANDBOX/tmp"
  export TEMP="$TMPDIR" TMP="$TMPDIR"
  STUB_BIN="$SANDBOX/bin"
  mkdir -p "$HOME" "$PI_ROOT" "$BACKUP_ROOT" "$LOCAL_EXT_ROOT" "$TMPDIR" "$STUB_BIN"
  unset PI_BACKUP_ASSUME_YES PI_BACKUP_EXCLUDE_AUTH KEEP_UNCOMPRESSED KEEP_OLD PKG_MANAGER
  ORIG_PATH="${ORIG_PATH:-$PATH}"
  export PATH="$STUB_BIN:$ORIG_PATH"
  stub_pi
  stub_mktemp_logger
}

sandbox_free() {
  [[ -n "$SANDBOX" && "$SANDBOX" == */pi-backup-test.* ]] && rm -rf "$SANDBOX"
  SANDBOX=""
}

# Abort hard if any root points outside the sandbox.
assert_in_sandbox() {
  [[ -n "$SANDBOX" && "$SANDBOX" == */pi-backup-test.* ]] || { echo "FATAL: no sandbox" >&2; exit 99; }
  local v
  for v in HOME PI_ROOT BACKUP_ROOT LOCAL_EXT_ROOT TMPDIR; do
    case "${!v}" in
      "$SANDBOX"/*) ;;
      *) echo "FATAL: $v=${!v} is outside sandbox $SANDBOX" >&2; exit 99 ;;
    esac
  done
}

# ── Fixtures ───────────────────────────────────────────────────
make_fixture() {
  assert_in_sandbox
  local a="$PI_ROOT/agent"
  mkdir -p "$a/skills/demo" "$a/projects-memory/proj-a" "$a/projects-memory/proj-b" \
           "$a/pi-hermes-memory" "$a/npm/ext1" "$a/npm/node_modules/junk" \
           "$a/pi-rtk" "$a/context-mode" "$a/sessions"
  echo '{"theme":"dark"}'                > "$a/settings.json"
  echo '{"anthropic":{"key":"DUMMY-TOKEN-NOT-REAL"}}' > "$a/auth.json"
  echo '{"models":[]}'                   > "$a/models.json"
  echo '{"enabled":true}'                > "$a/pi-rtk/config.json"
  echo '{"x":1}'                         > "$a/context-mode/config.json"
  echo "demo skill"                      > "$a/skills/demo/SKILL.md"
  echo "memory a"                        > "$a/projects-memory/proj-a/notes.md"
  echo "memory b"                        > "$a/projects-memory/proj-b/notes.md"
  echo "# memory"                        > "$a/pi-hermes-memory/MEMORY.md"
  echo "# user"                          > "$a/pi-hermes-memory/USER.md"
  echo '{"name":"ext1"}'                 > "$a/npm/ext1/package.json"
  echo "junk"                            > "$a/npm/node_modules/junk/index.js"
  echo "session"                         > "$a/sessions/s1.jsonl"
  echo '{"name":"dep"}'                  > "$a/npm/node_modules/junk/package.json"
  echo '{"lock":1}'                      > "$a/npm/ext1/package-lock.json"
  echo "# failures"                      > "$a/pi-hermes-memory/failures.md"
  echo "# retired"                       > "$a/pi-hermes-memory/retired-memory.md"
  echo '{"trust":[]}'                    > "$a/trust.json"
  mkdir -p "$a/pi-hermes-memory-cleanup"; echo '{"s":1}' > "$a/pi-hermes-memory-cleanup/scoped-memory.json"
  local d
  for d in 20260101 20260102 20260103 20260104 20260105 20260106 20260107; do
    mkdir -p "$a/hermes-cleanup/$d"; echo "cleanup $d" > "$a/hermes-cleanup/$d/note.txt"
  done
  mkdir -p "$a/hermes-cleanup/not-a-timestamp"; echo x > "$a/hermes-cleanup/not-a-timestamp/f"
  mkdir -p "$LOCAL_EXT_ROOT/pi-timeout/src" "$LOCAL_EXT_ROOT/pi-timeout/node_modules/x" "$LOCAL_EXT_ROOT/pi-timeout/.git"
  echo "export {}"                       > "$LOCAL_EXT_ROOT/pi-timeout/src/index.ts"
  echo "dep"                             > "$LOCAL_EXT_ROOT/pi-timeout/node_modules/x/i.js"
  echo "ignored"                         > "$LOCAL_EXT_ROOT/pi-timeout/.gitignore"
  echo "log"                             > "$LOCAL_EXT_ROOT/pi-timeout/debug.log"
  echo "gitjunk"                         > "$LOCAL_EXT_ROOT/pi-timeout/.git/HEAD"
}

# ── Stubs ──────────────────────────────────────────────────────
stub_pi() {
  printf '#!/bin/sh\necho "pi 0.0.0-stub"\n' > "$STUB_BIN/pi"; chmod +x "$STUB_BIN/pi"
}

# Wrap mktemp so tests can see every temp path a script creates (BSD mktemp ignores TMPDIR when
# called without a template, which would otherwise hide leaks outside the sandbox).
stub_mktemp_logger() {
  local real; real="$(command -v mktemp)"
  MKTEMP_LOG="$SANDBOX/mktemp.log"; : > "$MKTEMP_LOG"
  printf '#!/bin/sh\nout=$("%s" "$@") || exit $?\necho "$out" >> "%s"\necho "$out"\n' "$real" "$MKTEMP_LOG" > "$STUB_BIN/mktemp"
  chmod +x "$STUB_BIN/mktemp"
}

# assert_no_temp_leak <label>: every mktemp result lives under TMPDIR and is gone; TMPDIR is empty.
assert_no_temp_leak() {
  local p
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    case "$p" in "$TMPDIR"/*) ;; *) _fail "$1: temp path outside TMPDIR: $p"; [[ -e "$p" ]] && rm -rf "$p" ;; esac
    [[ -e "$p" ]] && { _fail "$1: leaked $p"; rm -rf "$p"; }
  done < "$MKTEMP_LOG"
  assert_empty_dir "$TMPDIR" "$1 (TMPDIR)"
}

# A stub 7z that always fails.
stub_7z_fail() {
  local n
  for n in 7zz 7z 7za; do   # the scripts prefer 7zz, then 7z, then 7za
    printf '#!/bin/sh\necho "stub 7z failure" >&2\nexit 1\n' > "$STUB_BIN/$n"; chmod +x "$STUB_BIN/$n"
  done
}

# ── Assertions ─────────────────────────────────────────────────
_fail() { FAILS=$((FAILS+1)); echo "    FAIL: $*" >&2; }
_pass() { PASSES=$((PASSES+1)); }

assert_eq()       { if [[ "$1" == "$2" ]]; then _pass; else _fail "${3:-assert_eq}: expected [$2] got [$1]"; fi; }
assert_file()     { if [[ -f "$1" ]]; then _pass; else _fail "missing file: $1"; fi; }
assert_no_file()  { if [[ ! -e "$1" ]]; then _pass; else _fail "unexpected path exists: $1"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then _pass; else _fail "${3:-output} lacks [$2]"; fi; }
assert_not_contains() { if ! grep -qF -- "$2" <<<"$1"; then _pass; else _fail "${3:-output} unexpectedly has [$2]"; fi; }
assert_status()   { if [[ "$1" == "$2" ]]; then _pass; else _fail "${3:-exit status}: expected $2 got $1"; fi; }
assert_nonzero()  { if [[ "$1" != "0" ]]; then _pass; else _fail "${2:-exit status}: expected non-zero"; fi; }

# assert_empty_dir <dir> <label>
assert_empty_dir() {
  local n; n="$(find "$1" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$n" == 0 ]]; then _pass; else _fail "$2 not empty: $(find "$1" -mindepth 1 | head -5 | tr '\n' ' ')"; fi
}

# assert_same_tree <a> <b> [label]
assert_same_tree() {
  if diff -r "$1" "$2" >/dev/null 2>&1; then _pass; else _fail "${3:-trees differ}: $(diff -rq "$1" "$2" 2>&1 | head -5 | tr '\n' ' ')"; fi
}

# count entries (non-recursive) matching glob in dir
count_glob() { local n=0 f; for f in $1; do [[ -e "$f" ]] && n=$((n+1)); done; echo "$n"; }

file_mode() { # portable octal mode
  if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

# ── Test runner ────────────────────────────────────────────────
# run_test <name> <function> : runs function once per flavor in a fresh sandbox.
# The function receives the flavor as $1.
run_test() {
  local name="$1" fn="$2" flavor before
  for flavor in "${FLAVORS[@]}"; do
    sandbox_new
    before=$FAILS
    echo "  - $name [$flavor]"
    "$fn" "$flavor" || _fail "$name [$flavor]: function returned non-zero"
    sandbox_free
  done
}

# run_test_once: for tests that are flavor-independent
run_test_once() {
  local name="$1" fn="$2"
  sandbox_new
  echo "  - $name"
  "$fn" || _fail "$name: function returned non-zero"
  sandbox_free
}

finish() {
  echo "  passed=$PASSES failed=$FAILS"
  [[ "$FAILS" == 0 ]]
}
