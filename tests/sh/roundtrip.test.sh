#!/bin/bash
# Characterization: backup then restore reproduces the tree byte-for-byte.
source "$(dirname "$0")/../helpers.sh"

have_7z() { command -v 7zz >/dev/null || command -v 7z >/dev/null || command -v 7za >/dev/null; }

roundtrip() { # <flavor> <dir|archive>
  local flavor="$1" mode="$2"
  make_fixture
  cp -a "$PI_ROOT" "$SANDBOX/orig-pi"
  cp -a "$LOCAL_EXT_ROOT" "$SANDBOX/orig-ext"

  if [[ "$mode" == dir ]]; then export KEEP_UNCOMPRESSED=1; else export KEEP_UNCOMPRESSED=0; fi
  run_script "$flavor" backup-pi >"$SANDBOX/backup.out" 2>&1
  assert_status "$?" 0 "backup"

  local target
  if [[ "$mode" == dir ]]; then target="$(ls -d "$BACKUP_ROOT"/pi-backup-*/ | head -1)"; target="${target%/}"
  else target="$(ls "$BACKUP_ROOT"/pi-backup-*.* | head -1)"; fi

  # Mutate: delete / change things the backup covers.
  rm -rf "$PI_ROOT/agent/skills" "$PI_ROOT/agent/projects-memory/proj-b" "$PI_ROOT/agent/npm/ext1"
  echo '{"theme":"light"}' > "$PI_ROOT/agent/settings.json"
  echo "changed" > "$LOCAL_EXT_ROOT/pi-timeout/src/index.ts"

  printf 'y\n' | run_script "$flavor" restore-pi "$target" >"$SANDBOX/restore.out" 2>&1
  assert_status "$?" 0 "restore"

  assert_same_tree "$PI_ROOT" "$SANDBOX/orig-pi" "pi tree after restore"
  assert_same_tree "$LOCAL_EXT_ROOT" "$SANDBOX/orig-ext" "local extension tree after restore"
}

t_dir()  { roundtrip "$1" dir; }
t_zip()  { have_7z && { echo "    (7z present: archive would be .7z; still valid)"; }; roundtrip "$1" archive; }

echo "roundtrip tests"
run_test "backup+restore round trip (directory)" t_dir
run_test "backup+restore round trip (archive)"   t_zip
finish
