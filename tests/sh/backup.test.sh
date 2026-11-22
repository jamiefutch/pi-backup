#!/bin/bash
source "$(dirname "$0")/../helpers.sh"

# Bug 3: internal (KEEP_UNCOMPRESSED=1) leaves exactly one dir, no archive.
t_internal_shape() {
  make_fixture
  local out; out="$(KEEP_UNCOMPRESSED=1 run_script "$1" backup-pi 2>&1)"
  assert_status "$?" 0 "internal backup"
  assert_eq "$(count_glob "$BACKUP_ROOT/pi-backup-*")" 1 "entries in internal root"
  assert_eq "$(count_glob "$BACKUP_ROOT/pi-backup-*.*")" 0 "archives in internal root"
  assert_contains "$out" "Staging:"
  assert_not_contains "$out" "Archive:"
}
t_external_shape() {
  make_fixture
  local out; out="$(KEEP_UNCOMPRESSED=0 run_script "$1" backup-pi 2>&1)"
  assert_status "$?" 0 "external backup"
  assert_eq "$(count_glob "$BACKUP_ROOT/pi-backup-*")" 1 "entries in external root"
  assert_eq "$(count_glob "$BACKUP_ROOT/pi-backup-*.*")" 1 "archives in external root"
  assert_contains "$out" "Archive:"
}
# Internal backup needs no zip tool.
t_internal_no_zip() {
  [[ "$1" == sh ]] || return 0
  make_fixture
  # PATH with essential tools only (no zip, no 7z)
  local d="$SANDBOX/minbin" t; mkdir -p "$d"
  for t in bash env date mkdir cp cat find sed sort basename dirname hostname whoami ls wc tr head rm tar du cut uname dirname rsync mktemp; do
    p="$(command -v $t 2>/dev/null)" && ln -sf "$p" "$d/$t"
  done
  ln -sf "$STUB_BIN/pi" "$d/pi"
  local out; out="$(PATH="$d" KEEP_UNCOMPRESSED=1 /bin/bash "$REPO_ROOT/backup-pi.sh" 2>&1)"
  assert_status "$?" 0 "internal backup without zip: $out"
}

# Bug 4: failed backup removes half-built staging dir.

# Bug 8: compression failure message has no literal property text.
t_compress_failure() {
  make_fixture
  stub_7z_fail
  local out; out="$(KEEP_UNCOMPRESSED=0 run_script "$1" backup-pi 2>&1)"
  assert_not_contains "$out" ".Exception.Message" "failure output"
  assert_contains "$out" "stub 7z failure" "failure output shows the real error or tool output"
}

# Compression failure is an error, keeps the intact staging dir, leaves no partial archive.
t_compress_failure_keeps_staging() {
  make_fixture
  stub_7z_fail
  KEEP_UNCOMPRESSED=0 run_script "$1" backup-pi >/dev/null 2>&1
  assert_nonzero "$?" "exit status after compression failure"
  assert_eq "$(count_glob "$BACKUP_ROOT/pi-backup-*.*")" 0 "partial archives"
  assert_eq "$(count_glob "$BACKUP_ROOT/pi-backup-*")" 1 "staging dirs kept"
}

# A half-built staging dir is removed when the backup fails part-way.
t_failure_removes_staging() {
  [[ "$(id -u)" == 0 ]] && return 0
  [[ "$(uname)" == MINGW* || "$(uname)" == MSYS* ]] && return 0
  make_fixture
  chmod 000 "$PI_ROOT/agent/skills"
  KEEP_UNCOMPRESSED=1 run_script "$1" backup-pi >/dev/null 2>&1
  local rc=$?
  chmod 755 "$PI_ROOT/agent/skills"
  assert_nonzero "$rc" "backup with unreadable skills dir"
  assert_eq "$(count_glob "$BACKUP_ROOT/pi-backup-*")" 0 "half-built staging dirs"
}

# Bug 5: credentials.
t_exclude_auth() {
  make_fixture
  PI_BACKUP_EXCLUDE_AUTH=1 KEEP_UNCOMPRESSED=1 run_script "$1" backup-pi >/dev/null 2>&1
  local d; d="$(ls -d "$BACKUP_ROOT"/pi-backup-*/ | head -1)"
  assert_no_file "${d}auth.json"
  assert_file "${d}settings.json"
}
t_auth_mode_and_warning() {
  make_fixture
  chmod 644 "$PI_ROOT/agent/auth.json"
  local out; out="$(KEEP_UNCOMPRESSED=1 run_script "$1" backup-pi 2>&1)"
  local d; d="$(ls -d "$BACKUP_ROOT"/pi-backup-*/ | head -1)"
  assert_file "${d}auth.json"
  [[ "$1" == sh || "$(uname)" != MINGW* ]] && assert_eq "$(file_mode "${d}auth.json")" 600 "auth.json mode in backup"
  assert_contains "$out" "auth.json" "credential warning"
  assert_contains "$out" "credentials" "credential warning"
}

# Bug 7: archive has a single top-level pi-backup-*/ entry.
t_archive_layout() {
  command -v 7zz >/dev/null || command -v 7z >/dev/null || { echo "    (skip: no 7-Zip)"; return 0; }
  make_fixture
  KEEP_UNCOMPRESSED=0 run_script "$1" backup-pi >/dev/null 2>&1
  local ar; ar="$(ls "$BACKUP_ROOT"/pi-backup-*.7z | head -1)"
  local tool; tool="$(command -v 7zz || command -v 7z)"
  local tops; tops="$("$tool" l -slt "$ar" | sed -n 's/^Path = //p' | grep -v "^$ar$" | cut -d/ -f1 | cut -d'\' -f1 | sort -u)"
  assert_eq "$(echo "$tops" | wc -l | tr -d ' ')" 1 "top-level entries: $tops"
  assert_contains "$tops" "pi-backup-"
}

echo "backup tests"
run_test "internal backup: one dir, no archive"   t_internal_shape
run_test "external backup: one archive"           t_external_shape
run_test "internal backup works without zip"      t_internal_no_zip
run_test "compression failure message"            t_compress_failure
run_test "compression failure keeps staging, no partial archive" t_compress_failure_keeps_staging
run_test "failed backup removes half-built staging" t_failure_removes_staging
run_test "EXCLUDE_AUTH omits auth.json"           t_exclude_auth
run_test "auth.json mode 600 and warning"         t_auth_mode_and_warning
run_test "archive has single top-level dir"       t_archive_layout
finish
