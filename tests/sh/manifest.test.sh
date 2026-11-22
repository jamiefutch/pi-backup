#!/bin/bash
source "$(dirname "$0")/../helpers.sh"

MANIFEST="$REPO_ROOT/backup-manifest.txt"

manifest_lines() { tr -d '\r' < "$MANIFEST" | grep -v '^#' | grep -v '^$'; }

t_lf_only() {
  if grep -q $'\r' "$MANIFEST"; then _fail "backup-manifest.txt contains CR characters"; else _pass; fi
  assert_contains "$(cat "$REPO_ROOT/.gitattributes")" "backup-manifest.txt text eol=lf" ".gitattributes"
}

# README tables must list exactly what the manifest backs up.
t_readme_in_sync() {
  local readme; readme="$(cat "$REPO_ROOT/README.md")"
  local kind a b c
  while IFS='|' read -r kind a b c; do
    case "$kind" in
      file)
        case "$b" in
          pi-hermes-memory/*) assert_contains "$readme" "\`${b#pi-hermes-memory/}\`" "README lacks $b" ;;
          *)                  assert_contains "$readme" "\`$b\`" "README lacks $b" ;;
        esac ;;
      dir|dir-each|recent) assert_contains "$readme" "~/.pi/$a/" "README lacks $a" ;;
      local-ext)           assert_contains "$readme" "$a/" "README lacks local extension $a" ;;
      npm)                 assert_contains "$readme" "~/.pi/$a/" "README lacks $a" ;;
    esac
  done < <(manifest_lines)

  # And the other direction: every config file named in the first two table rows is in the manifest.
  local row tok
  while IFS= read -r row; do
    while IFS= read -r tok; do
      [[ -n "$tok" ]] || continue
      if manifest_lines | cut -d'|' -f3 | grep -qxF "$tok"; then _pass; else _fail "README names \`$tok\` but the manifest does not"; fi
    done < <(grep -o '`[^`]*`' <<<"$row" | tr -d '`')
  done < <(grep -E '^\| \*\*(Core config|Extension configs)\*\*' "$REPO_ROOT/README.md" | sed 's/^| \*\*[^|]*\*\* |//')
}

# bash and pwsh must back up exactly the same files with the same contents.
t_flavor_parity() {
  [[ "$HAVE_PWSH" == 1 ]] || { echo "    (skip: no pwsh)"; return 0; }
  make_fixture
  local root_sh="$SANDBOX/b-sh" root_ps="$SANDBOX/b-ps"
  KEEP_UNCOMPRESSED=1 BACKUP_ROOT="$root_sh" run_script sh  backup-pi >/dev/null 2>&1
  KEEP_UNCOMPRESSED=1 BACKUP_ROOT="$root_ps" run_script ps1 backup-pi >/dev/null 2>&1
  local d_sh d_ps; d_sh="$(ls -d "$root_sh"/pi-backup-*/ | head -1)"; d_ps="$(ls -d "$root_ps"/pi-backup-*/ | head -1)"
  local l_sh l_ps
  l_sh="$(cd "$d_sh" && find . -type f ! -name MANIFEST.txt | sort)"
  l_ps="$(cd "$d_ps" && find . -type f ! -name MANIFEST.txt | sort)"
  assert_eq "$l_ps" "$l_sh" "file sets (ps1 vs sh)"
  if diff -r -x MANIFEST.txt "$d_sh" "$d_ps" >/dev/null 2>&1; then _pass; else _fail "contents differ: $(diff -rq -x MANIFEST.txt "$d_sh" "$d_ps" | head -3 | tr '\n' ' ')"; fi
}

echo "manifest tests"
run_test_once "manifest is LF-only"                 t_lf_only
run_test_once "README matches the manifest"         t_readme_in_sync
run_test_once "bash and pwsh back up the same set"  t_flavor_parity
finish
