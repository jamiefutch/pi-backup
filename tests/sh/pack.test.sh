#!/bin/bash
# D3: the published package contains only the intended files (no tests, dist, backups, credentials).
source "$(dirname "$0")/../helpers.sh"

t_pack_contents() {
  command -v npm >/dev/null || { echo "    (skip: no npm)"; return 0; }
  local json files bad
  json="$(cd "$REPO_ROOT" && npm pack --dry-run --json 2>/dev/null)" || { _fail "npm pack --dry-run failed"; return 0; }
  files="$(node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));console.log(j[0].files.map(f=>f.path).join("\n"))' <<<"$json")"
  assert_contains "$files" "extensions/pi-backup-manager.ts"
  for f in backup-pi.sh restore-pi.sh pi-clean-reinstall.sh backup-pi.ps1 restore-pi.ps1 pi-clean-reinstall.ps1 backup-manifest.txt README.md CHANGELOG.md LICENSE package.json; do
    assert_contains "$files" "$f" "published files"
  done
  bad="$(grep -E '^(tests|dist|docs|\.pi|\.github|node_modules)/|\.(7z|zip)$|auth\.json' <<<"$files" || true)"
  assert_eq "$bad" "" "unexpected published files"
}
echo "pack tests"
run_test_once "npm pack publishes only intended files" t_pack_contents
finish
