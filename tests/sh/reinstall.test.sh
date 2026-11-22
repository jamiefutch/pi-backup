#!/bin/bash
# Clean-reinstall tests use STUB bun/pi only; the real package manager is never called.
source "$(dirname "$0")/../helpers.sh"

setup_stubs() {
  BUN_LOG="$SANDBOX/bun.log"; : > "$BUN_LOG"
  printf '#!/bin/sh\necho "$@" >> "%s"\ncase "$1" in\n  add) [ "$STUB_BUN_FAIL" = add ] && exit 1 ;;\nesac\nexit 0\n' "$BUN_LOG" > "$STUB_BIN/bun"
  chmod +x "$STUB_BIN/bun"
  # pi stub: succeeds and creates a fresh ~/.pi/agent, unless told to fail
  printf '#!/bin/sh\n[ "$STUB_PI_FAIL" = 1 ] && exit 1\nmkdir -p "%s/agent"\necho "pi 9.9.9-stub"\n' "$PI_ROOT" > "$STUB_BIN/pi"
  chmod +x "$STUB_BIN/pi"
  export PKG_MANAGER=bun
  rm -rf "$PI_ROOT"; mkdir -p "$PI_ROOT/agent"; echo precious > "$PI_ROOT/agent/marker"
}
with_backup() { mkdir -p "$BACKUP_ROOT/pi-backup-20260101-000000"; }
skip_win() { [[ "$(uname)" == MINGW* || "$(uname)" == MSYS* ]]; }

t_success() {
  skip_win && return 0
  setup_stubs; with_backup
  printf 'yes\n' | run_script "$1" pi-clean-reinstall >"$SANDBOX/out" 2>&1
  assert_status "$?" 0 "reinstall: $(tail -3 "$SANDBOX/out")"
  assert_no_file "$PI_ROOT/agent/marker"
  assert_eq "$(count_glob "$PI_ROOT.pre-reinstall-*")" 0 "moved-aside copies"
  assert_contains "$(cat "$BUN_LOG")" "add -g"
}
t_keep_old() {
  skip_win && return 0
  setup_stubs; with_backup
  printf 'yes\n' | KEEP_OLD=1 run_script "$1" pi-clean-reinstall >/dev/null 2>&1
  assert_eq "$(count_glob "$PI_ROOT.pre-reinstall-*")" 1 "kept copy"
  assert_file "$(ls -d "$PI_ROOT".pre-reinstall-* | head -1)/agent/marker"
}
t_install_failure() {
  skip_win && return 0
  setup_stubs; with_backup
  printf 'yes\n' | STUB_BUN_FAIL=add run_script "$1" pi-clean-reinstall >/dev/null 2>&1
  assert_nonzero "$?" "install failure exit"
  assert_file "$PI_ROOT/agent/marker"
  assert_eq "$(count_glob "$PI_ROOT.pre-reinstall-*")" 0 "leftover moved-aside dirs"
}
t_verify_failure() {
  skip_win && return 0
  setup_stubs; with_backup
  printf 'yes\n' | STUB_PI_FAIL=1 run_script "$1" pi-clean-reinstall >/dev/null 2>&1
  assert_nonzero "$?" "verify failure exit"
  assert_file "$PI_ROOT/agent/marker"
}
t_no_backup_prompt() {
  skip_win && return 0
  setup_stubs
  # Only 'yes': the extra confirmation cannot be read -> abort, nothing touched.
  printf 'yes\n' | run_script "$1" pi-clean-reinstall >"$SANDBOX/out" 2>&1
  assert_nonzero "$?" "no-backup abort"
  assert_file "$PI_ROOT/agent/marker"
  assert_not_contains "$(cat "$BUN_LOG")" "add"
  # With the extra confirmation it proceeds.
  printf 'no backup\nyes\n' | run_script "$1" pi-clean-reinstall >/dev/null 2>&1
  assert_status "$?" 0 "no-backup with extra confirmation"
  assert_no_file "$PI_ROOT/agent/marker"
}
t_abort() {
  skip_win && return 0
  setup_stubs; with_backup
  printf 'nope\n' | run_script "$1" pi-clean-reinstall >/dev/null 2>&1
  assert_nonzero "$?" "abort"
  assert_file "$PI_ROOT/agent/marker"
  assert_eq "$(cat "$BUN_LOG")" "" "no package manager calls"
}
t_no_stdin() {
  skip_win && return 0
  setup_stubs; with_backup
  run_script "$1" pi-clean-reinstall </dev/null >/dev/null 2>&1
  assert_nonzero "$?" "no stdin"
  assert_file "$PI_ROOT/agent/marker"
}
# Dead code and misleading messages are gone.
t_no_dead_code() {
  assert_eq "$(grep -c 'BUN_HOME' "$REPO_ROOT"/pi-clean-reinstall.* | grep -v ':0' | wc -l | tr -d ' ')" 0 "BUN_HOME references"
  assert_eq "$(grep -c 'fresh ~/.pi structure created' "$REPO_ROOT"/pi-clean-reinstall.* | grep -v ':0' | wc -l | tr -d ' ')" 0 "misleading step-4 message"
}

echo "reinstall tests"
run_test "success deletes the old tree"          t_success
run_test "KEEP_OLD keeps the old tree"           t_keep_old
run_test "install failure leaves ~/.pi intact"   t_install_failure
run_test "verify failure rolls back"             t_verify_failure
run_test "no backup needs extra confirmation"    t_no_backup_prompt
run_test "wrong confirmation aborts untouched"   t_abort
run_test "no stdin aborts untouched"             t_no_stdin
run_test_once "no dead code / misleading messages" t_no_dead_code
finish
