#!/bin/bash
source "$(dirname "$0")/../helpers.sh"

t_bash_syntax() {
  local f
  for f in backup-pi.sh restore-pi.sh pi-clean-reinstall.sh; do
    bash -n "$REPO_ROOT/$f" 2>/dev/null; assert_status "$?" 0 "bash -n $f"
  done
}
t_pwsh_parse() {
  [[ "$HAVE_PWSH" == 1 ]] || { echo "    (skip: no pwsh)"; return 0; }
  local f out
  for f in backup-pi.ps1 restore-pi.ps1 pi-clean-reinstall.ps1 tests/ps1/archive-layout.ps1; do
    out="$(PI_LINT_FILE="$REPO_ROOT/$f" pwsh -NoProfile -Command '$t=$null;$e=$null;[System.Management.Automation.Language.Parser]::ParseFile($env:PI_LINT_FILE,[ref]$t,[ref]$e)|Out-Null; if($e.Count){$e|%{$_.Message};exit 1}' 2>&1)"
    assert_status "$?" 0 "pwsh parse $f: $out"
  done
}
# Bug 8: "$_.Exception.Message" inside a string interpolates $_ and prints the property name literally.
t_no_bad_interpolation() {
  local hits
  hits="$(grep -nE '"[^"]*\$_\.[A-Za-z]' "$REPO_ROOT"/*.ps1 | grep -v '\$(\$_\.' || true)"
  assert_eq "$hits" "" "bad \$_.Prop interpolation"
}
# The TUI executes scripts by path, so git must record the exec bit.
t_exec_bits() {
  local f mode
  for f in backup-pi.sh restore-pi.sh pi-clean-reinstall.sh; do
    mode="$(git -C "$REPO_ROOT" ls-files -s "$f" | cut -d' ' -f1)"
    assert_eq "$mode" 100755 "git mode of $f"
  done
}
echo "lint tests"
run_test_once "bash syntax"                   t_bash_syntax
run_test_once "pwsh parse"                    t_pwsh_parse
run_test_once "no \$_.Prop in strings (ps1)"  t_no_bad_interpolation
run_test_once "scripts are executable in git" t_exec_bits
finish
