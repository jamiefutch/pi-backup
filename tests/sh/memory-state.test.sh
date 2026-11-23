#!/bin/bash
# Memory database, extension state and opt-in items: what is backed up, what is restored.
source "$(dirname "$0")/../helpers.sh"

have_sqlite3() { command -v sqlite3 >/dev/null 2>&1; }
have_python3() { command -v python3 >/dev/null 2>&1; }

# A memory database in WAL mode that holds committed rows not yet checkpointed into the main file.
# A python process keeps the connection (and the -wal file) open while the backup runs.
# Sets WRITER_PID and DB.
make_live_wal_db() { # <db path>
  DB="$1"; mkdir -p "$(dirname "$DB")"
  python3 - "$DB" <<'PY' &
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("PRAGMA journal_mode=WAL")
c.execute("PRAGMA wal_autocheckpoint=0")
c.execute("CREATE TABLE IF NOT EXISTS memory(id INTEGER PRIMARY KEY, body TEXT)")
c.execute("INSERT INTO memory(body) VALUES ('written just before backup')")
c.commit()

time.sleep(60)
PY
  WRITER_PID=$!
  # wait until the writer has committed (its -wal file exists and is non-empty)
  local i=0
  while [[ ! -s "$DB-wal" && $i -lt 50 ]]; do sleep 0.1; i=$((i+1)); done
}
stop_writer() { [[ -n "${WRITER_PID:-}" ]] && kill "$WRITER_PID" 2>/dev/null; wait "${WRITER_PID:-}" 2>/dev/null || true; WRITER_PID=""; }

backup_dir() { # <flavor> -> sets BK to the staging directory of a directory-mode backup
  KEEP_UNCOMPRESSED=1 run_script "$1" backup-pi >"$SANDBOX/backup.out" 2>&1
  BK="$(ls -d "$BACKUP_ROOT"/pi-backup-*/ | head -1)"; BK="${BK%/}"
}

# Default run: the memory database and extension state are in, opt-in items are out.
t_default_scope() {
  have_sqlite3 || { echo "    (skip: no sqlite3)"; return 0; }
  make_fixture
  mkdir -p "$PI_ROOT/agent/pi-hermes-memory/skills/fix-x" "$PI_ROOT/agent/missions/index" \
           "$PI_ROOT/agent/extensions/pi-rtk-optimizer" "$PI_ROOT/agent/git/github.com/x" "$PI_ROOT/agent/bin"
  echo "skill"  > "$PI_ROOT/agent/pi-hermes-memory/skills/fix-x/SKILL.md"
  echo "mission" > "$PI_ROOT/agent/missions/index/m.json"
  echo "ext"    > "$PI_ROOT/agent/extensions/pi-rtk-optimizer/index.ts"
  echo "{}"     > "$PI_ROOT/agent/anti-stall.json"
  echo "{}"     > "$PI_ROOT/agent/models-store.json"
  mkdir -p "$PI_ROOT/agent/pi-subagents"; echo "{}" > "$PI_ROOT/agent/pi-subagents/last-seen-version.json"
  echo "x"      > "$PI_ROOT/agent/git/github.com/x/README"
  echo "fd"     > "$PI_ROOT/agent/bin/fd"
  sqlite3 "$PI_ROOT/agent/pi-hermes-memory/sessions.db" "CREATE TABLE m(x); INSERT INTO m VALUES('memo');"
  echo "stale" > "$PI_ROOT/agent/pi-hermes-memory/sessions.db-journal"
  echo "migrated" > "$PI_ROOT/agent/pi-hermes-memory/.skills-migrated-to-extension-storage"
  backup_dir "$1"
  assert_status "$?" 0 "backup"
  assert_file "$BK/pi-hermes-memory/sessions.db"
  assert_file "$BK/pi-hermes-memory/skills/fix-x/SKILL.md"
  assert_file "$BK/pi-hermes-memory/.skills-migrated-to-extension-storage"
  assert_file "$BK/missions/index/m.json"
  assert_file "$BK/extensions/pi-rtk-optimizer/index.ts"
  assert_file "$BK/anti-stall.json"
  assert_file "$BK/models-store.json"
  assert_file "$BK/pi-subagents/last-seen-version.json"
  assert_no_file "$BK/sessions"
  assert_no_file "$BK/git"
  assert_no_file "$BK/bin"
  assert_no_file "$BK/pi-hermes-memory/sessions.db-journal"
  assert_no_file "$BK/pi-hermes-memory/sessions.db-wal"
  assert_no_file "$BK/pi-hermes-memory/sessions.db-shm"
  local out; out="$(cat "$SANDBOX/backup.out")"
  assert_contains "$out" "PI_BACKUP_INCLUDE_SESSIONS=1" "backup notes the opt-in for sessions"
  # the snapshot is a real, readable database with the committed row
  assert_no_file "$BK/pi-hermes-memory/sessions.db-wal"
  assert_eq "$(sqlite3 "$BK/pi-hermes-memory/sessions.db" 'select x from m')" "memo" "snapshot contents"
}

# Opt-in: each variable adds its directory, and only that one.
t_opt_in() {
  make_fixture
  mkdir -p "$PI_ROOT/agent/git/github.com/x" "$PI_ROOT/agent/bin"
  echo "x" > "$PI_ROOT/agent/git/github.com/x/README"
  echo "fd" > "$PI_ROOT/agent/bin/fd"
  PI_BACKUP_INCLUDE_SESSIONS=1 PI_BACKUP_INCLUDE_GIT=1 backup_dir "$1"
  assert_status "$?" 0 "backup with opt-ins"
  assert_file "$BK/sessions/s1.jsonl"
  assert_file "$BK/git/github.com/x/README"
  assert_no_file "$BK/bin"
}

t_opt_in_bin() {
  make_fixture
  mkdir -p "$PI_ROOT/agent/bin"; echo "fd" > "$PI_ROOT/agent/bin/fd"
  PI_BACKUP_INCLUDE_BIN=1 backup_dir "$1"
  assert_status "$?" 0 "backup with bin opt-in"
  assert_file "$BK/bin/fd"
}

# The snapshot includes committed rows that are still only in the -wal file.
t_live_wal() {
  have_sqlite3 || { echo "    (skip: no sqlite3)"; return 0; }
  have_python3 || { echo "    (skip: no python3)"; return 0; }
  make_fixture
  make_live_wal_db "$PI_ROOT/agent/pi-hermes-memory/sessions.db"
  [[ -s "$DB-wal" ]] || { _fail "writer did not leave a -wal file"; stop_writer; return 0; }
  backup_dir "$1"
  local rc=$?
  stop_writer
  assert_status "$rc" 0 "backup while a writer holds the database"
  assert_no_file "$BK/pi-hermes-memory/sessions.db-wal"
  assert_eq "$(sqlite3 "$BK/pi-hermes-memory/sessions.db" 'select body from memory')" "written just before backup" "WAL row in snapshot"
}

# Restore replaces the database and drops stale -wal/-shm/-journal next to it.
t_restore_clears_stale_wal() {
  have_sqlite3 || { echo "    (skip: no sqlite3)"; return 0; }
  make_fixture
  sqlite3 "$PI_ROOT/agent/pi-hermes-memory/sessions.db" "CREATE TABLE m(x); INSERT INTO m VALUES('from backup');"
  backup_dir "$1"
  # a stale journal from a different database would corrupt the restored file if it were left behind
  sqlite3 "$PI_ROOT/agent/pi-hermes-memory/sessions.db" "INSERT INTO m VALUES('changed after backup');" >/dev/null
  printf 'garbage' > "$PI_ROOT/agent/pi-hermes-memory/sessions.db-wal"
  printf 'garbage' > "$PI_ROOT/agent/pi-hermes-memory/sessions.db-shm"
  printf 'y\n' | run_script "$1" restore-pi "$BK" >"$SANDBOX/restore.out" 2>&1
  assert_status "$?" 0 "restore"
  assert_no_file "$PI_ROOT/agent/pi-hermes-memory/sessions.db-wal"
  assert_no_file "$PI_ROOT/agent/pi-hermes-memory/sessions.db-shm"
  assert_eq "$(sqlite3 "$PI_ROOT/agent/pi-hermes-memory/sessions.db" 'select x from m')" "from backup" "restored contents"
  assert_eq "$(sqlite3 "$PI_ROOT/agent/pi-hermes-memory/sessions.db" 'pragma integrity_check')" "ok" "integrity after restore"
}

# A default backup has no sessions/, so restore must not warn about it.
t_restore_quiet_for_optional() {
  make_fixture
  backup_dir "$1"
  printf 'y\n' | run_script "$1" restore-pi "$BK" >"$SANDBOX/restore.out" 2>&1
  assert_status "$?" 0 "restore"
  assert_not_contains "$(cat "$SANDBOX/restore.out")" "sessions/" "restore output for the optional sessions dir"
}

echo "memory-state tests"
run_test "default scope includes memory db, skills and state; excludes opt-ins" t_default_scope
run_test "PI_BACKUP_INCLUDE_SESSIONS and _GIT add those directories"             t_opt_in
run_test "PI_BACKUP_INCLUDE_BIN adds bin"                                       t_opt_in_bin
run_test "snapshot keeps rows that are only in the -wal file"                   t_live_wal
run_test "restore removes stale -wal/-shm and restores the database"            t_restore_clears_stale_wal
run_test "restore is silent for optional items absent from the backup"         t_restore_quiet_for_optional
finish
