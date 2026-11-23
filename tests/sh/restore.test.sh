#!/bin/bash
source "$(dirname "$0")/../helpers.sh"

make_dir_backup() { # <flavor> -> sets BK
  make_fixture
  KEEP_UNCOMPRESSED=1 run_script "$1" backup-pi >/dev/null 2>&1
  BK="$(ls -d "$BACKUP_ROOT"/pi-backup-*/ | head -1)"; BK="${BK%/}"
  rm -rf "$PI_ROOT/agent/skills"
}

# Bug 1: restore with no stdin must explain itself, and PI_BACKUP_ASSUME_YES must work.
t_no_stdin() {
  make_dir_backup "$1"
  local out rc
  out="$(run_script "$1" restore-pi "$BK" </dev/null 2>&1)"; rc=$?
  assert_nonzero "$rc" "restore without stdin"
  assert_contains "$out" "PI_BACKUP_ASSUME_YES" "no-stdin message"
  assert_no_file "$PI_ROOT/agent/skills"
}
t_assume_yes() {
  make_dir_backup "$1"
  local out rc
  out="$(PI_BACKUP_ASSUME_YES=1 run_script "$1" restore-pi "$BK" </dev/null 2>&1)"; rc=$?
  assert_status "$rc" 0 "restore with ASSUME_YES"
  assert_file "$PI_ROOT/agent/skills/demo/SKILL.md"
}

# Bug 4: temp dirs must not leak.
make_archive() { # <flavor> -> sets AR
  make_fixture
  KEEP_UNCOMPRESSED=0 run_script "$1" backup-pi >/dev/null 2>&1
  AR="$(ls "$BACKUP_ROOT"/pi-backup-*.* | head -1)"
}
t_leak_abort() {
  make_archive "$1"
  printf 'n\n' | run_script "$1" restore-pi "$AR" >/dev/null 2>&1
  assert_no_temp_leak "TMPDIR after abort"
}
t_leak_success() {
  make_archive "$1"
  printf 'y\n' | run_script "$1" restore-pi "$AR" >/dev/null 2>&1
  assert_no_temp_leak "TMPDIR after success"
}
t_leak_truncated() {
  make_archive "$1"
  head -c 100 "$AR" > "$SANDBOX/trunc.zip"
  printf 'y\n' | run_script "$1" restore-pi "$SANDBOX/trunc.zip" >/dev/null 2>&1
  assert_nonzero "$?" "truncated archive restore"
  assert_no_temp_leak "TMPDIR after truncated archive"
}
t_leak_midfail() {
  make_archive "$1"
  # Make the destination unwritable so restore fails part-way.
  rm -rf "$PI_ROOT/agent/skills"; mkdir -p "$PI_ROOT/agent"
  chmod 555 "$PI_ROOT/agent"
  printf 'y\n' | run_script "$1" restore-pi "$AR" >/dev/null 2>&1
  local rc=$?
  chmod 755 "$PI_ROOT/agent"
  if [[ "$(id -u)" == 0 ]]; then return 0; fi   # root ignores modes
  assert_nonzero "$rc" "mid-restore failure"
  assert_no_temp_leak "TMPDIR after mid-restore failure"
}

# Bug 2 (script side): warn when a Pi process is running, but do not block.
t_running_warning() {
  make_dir_backup "$1"
  if [[ "$(uname)" == MINGW* || "$(uname)" == MSYS* ]]; then echo "    (skip: uses a pgrep stub)"; return 0; fi
  # Unix: both flavors call pgrep, so a stub on PATH simulates a running Pi.
  printf '#!/bin/sh\necho 4242\nexit 0\n' > "$STUB_BIN/pgrep"; chmod +x "$STUB_BIN/pgrep"
  local out rc
  out="$(PI_BACKUP_ASSUME_YES=1 run_script "$1" restore-pi "$BK" </dev/null 2>&1)"; rc=$?
  assert_status "$rc" 0 "restore proceeds despite warning"
  assert_contains "$out" "appears to be running" "running-Pi warning"
}

t_auth_mode() {
  [[ "$(uname)" == MINGW* || "$(uname)" == MSYS* ]] && return 0
  make_dir_backup "$1"
  chmod 644 "$BK/auth.json"; rm -f "$PI_ROOT/agent/auth.json"
  PI_BACKUP_ASSUME_YES=1 run_script "$1" restore-pi "$BK" </dev/null >/dev/null 2>&1
  assert_eq "$(file_mode "$PI_ROOT/agent/auth.json")" 600 "restored auth.json mode"
}

echo "restore tests"
run_test "no stdin fails with a clear message"      t_no_stdin
run_test "PI_BACKUP_ASSUME_YES skips the prompt"    t_assume_yes
run_test "no temp leak: abort"                      t_leak_abort
run_test "no temp leak: success"                    t_leak_success
run_test "no temp leak: truncated archive"          t_leak_truncated
run_test "no temp leak: mid-restore failure"        t_leak_midfail
run_test "restored auth.json is mode 600"            t_auth_mode
run_test "warns when Pi is running"                 t_running_warning
finish
