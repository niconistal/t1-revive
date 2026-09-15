#!/usr/bin/env bats
# lib/report.sh: the shape of the bundle a tester pastes into an issue.
#
# The report is read-only by construction, so nothing is stubbed for safety here; journalctl is
# replaced by a stub so the bundle does not depend on this machine's journal (and so the same
# command run twice really produces the same bytes). Everything else - DMI, sysfs, lsblk, the
# state and log directories - comes from test/fixtures and $T1R_TMP.

load test_helper/common

setup() {
  t1r_env
  [[ -f $T1R_REPO/lib/report.sh ]] || skip "lib/report.sh not present"
  t1r_use_sysfs recovery
  t1r_use_dmi 14_3
  t1r_use_lsblk one-esp
  # a journal with nothing in it: deterministic, and no host state in the bundle
  t1r_stub_bin journalctl <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
}

report_load() {
  t1r_load discover report
  t1r_need cmd_report report_body
}

# report_sections OUTPUT: the section names, in the order they appear.
report_sections() { printf '%s\n' "$1" | sed -n 's/^section: //p' | paste -sd' '; }

# documented_sections: the section order from the table in docs/diagnostics.md.
documented_sections() {
  sed -n '/^| Section | What it holds |/,/^$/p' "$T1R_REPO/docs/diagnostics.md" \
    | sed -n 's/^| `\([a-z0-9]*\)` |.*/\1/p' | paste -sd' '
}

# --- structure -----------------------------------------------------------------------------
@test "report: the sections come in the order docs/diagnostics.md documents" {
  report_load
  t1r_run cmd_report
  assert_status 0
  local want; want=$(documented_sections)
  [[ -n $want ]] || { echo "could not read the section table from docs/diagnostics.md" >&2; return 1; }
  assert_eq "$want" "$(report_sections "$output")"
}

@test "report: every line is key: value, a section header or a diagnostic line" {
  report_load
  t1r_run cmd_report
  assert_status 0
  local line key bad=0
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    [[ $line == 't1-revive-diagnostic v=1 '* ]] && continue
    key=${line%%: *}
    [[ -n $key && $key != *[[:space:]]* && $line == "$key: "* ]] && continue
    echo "not a key: value or diagnostic line: $line" >&2; bad=1
  done <<<"$output"
  return $bad
}

@test "report: the last line is report-sha256 over everything above it" {
  report_load
  local out=$T1R_TMP/report.txt
  t1r_run cmd_report --out "$out"
  assert_status 0
  local last want
  last=$(tail -n 1 "$out")
  [[ $last == report-sha256:\ * ]] || { echo "last line is not the checksum: $last" >&2; return 1; }
  # docs/diagnostics.md tells the reader to check it with: head -n -1 report.txt | sha256sum
  want=$(head -n -1 "$out" | sha256sum | awk '{print $1}')
  assert_eq "report-sha256: $want" "$last"
}

@test "report: --out writes the same bundle as stdout" {
  report_load
  local out=$T1R_TMP/report.txt plain=$T1R_TMP/report-stdout.txt
  # stdout only: the "run with sudo" hint is a stderr line, not part of the bundle
  cmd_report >"$plain" 2>/dev/null
  t1r_run cmd_report --out "$out"
  assert_status 0
  assert_contains "$output" "report written to $out"
  # report-time has minute precision, so a run that straddles a minute differs in that line
  # (and therefore in the checksum) only; everything else must be identical.
  local a b
  a=$(grep -v '^report-time: ' "$plain" | grep -v '^report-sha256: ')
  b=$(grep -v '^report-time: ' "$out" | grep -v '^report-sha256: ')
  assert_eq "$a" "$b"
  # the bundle on stdout carries its own valid checksum too
  assert_eq "report-sha256: $(head -n -1 "$plain" | sha256sum | awk '{print $1}')" "$(tail -n 1 "$plain")"
  # and so does the file
  assert_eq "report-sha256: $(head -n -1 "$out" | sha256sum | awk '{print $1}')" "$(tail -n 1 "$out")"
}

# --- redaction -------------------------------------------------------------------------------
@test "report: no line but the checksum carries a 16+ hex run" {
  report_load
  local out=$T1R_TMP/report.txt
  t1r_run cmd_report --out "$out"
  assert_status 0
  local hits
  hits=$(head -n -1 "$out" | grep -nE '[0-9a-fA-F]{16,}' || true)
  [[ -z $hits ]] || { printf 'unredacted hex runs in the bundle:\n%s\n' "$hits" >&2; return 1; }
}

@test "report: the body goes through redact" {
  report_load
  # a log file with an identifier-looking line: the diagnostic section reads the log directory
  local h; h=$(printf '%s%s' 0123456789 abcdef)
  printf 't1-revive-diagnostic v=1 component=test step=provision result=ok nonce=%s\n' "$h" \
    >"$T1R_LOG/planted.log"
  t1r_run cmd_report
  assert_status 0
  refute_contains "$output" "$h"
  assert_contains "$output" "<hex>"
}

# --- content ---------------------------------------------------------------------------------
@test "report: reports the fixture model, T1 state and ESP without root" {
  [[ ${EUID:-$(id -u)} -ne 0 ]] || skip "this test describes the bundle a normal user gets"
  report_load
  t1r_run cmd_report
  assert_status 0
  assert_contains "$output" "privileges: user"
  assert_contains "$output" "model: MacBookPro14,3"
  assert_contains "$output" "model-status: tested"
  assert_contains "$output" "t1-state: recovery"
  assert_contains "$output" "esp[0].device: /dev/sdz1"
  assert_contains "$output" "esp-candidates: 1"
  assert_contains "$output" "report-format: 1"
  assert_contains "$output" "tool-version: $(tr -d '\n' <"$T1R_REPO/VERSION")"
}

@test "report: an unmounted ESP is looked at through a read-only probe (issue #2)" {
  # Apple's ESP on a dual-boot Mac is never mounted while Linux runs; without the probe the
  # bundle could not tell an intact machine from a wiped one.
  t1r_stub_mount; t1r_stub_apple_data
  report_load
  t1r_run cmd_report
  assert_status 0
  assert_contains "$output" "esp[0].mounted: no"
  assert_contains "$output" "esp[0].efi-apple: yes"
  assert_contains "$output" "esp[0].embeddedos: yes"
  assert_contains "$output" "esp[0].FDRData: yes"
  assert_contains "$output" "esp[0].note: probed-read-only"
  assert_contains "$output" "esp-selected: /dev/sdz1"
  assert_contains "$output" "esp-selected-why: the-only-EFI-system-partition"
  refute_contains "$output" "SYNTHETIC-FDR-PLACEHOLDER"
  assert_contains "$(cat "$T1R_TMP/mount.log")" "-o ro,nosuid,nodev,noexec /dev/sdz1"
}

@test "report: an unmounted ESP that cannot be probed keeps the '?' and says so" {
  export T1R_ESP_PROBE=0
  report_load
  t1r_run cmd_report
  assert_status 0
  assert_contains "$output" "esp[0].efi-apple: ?"
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then assert_contains "$output" "esp[0].note: not-mounted"
  else assert_contains "$output" "esp[0].note: not-mounted-needs-root"; fi
}

@test "report: counts the step markers and the EFI backups it finds" {
  report_load
  t1r_step_marker boot
  : >"$T1R_STATE/efi-backup-19700101-000000.tar"
  t1r_run cmd_report
  assert_status 0
  assert_contains "$output" "state-dir: present"
  assert_contains "$output" "step-markers: boot.done"
  assert_contains "$output" "efi-backups: 1"
}

@test "report: counts diagnostic lines from the log directory and from the journal" {
  report_load
  t1r_stub_bin journalctl <<'STUB'
#!/usr/bin/env bash
printf 't1-revive-diagnostic v=1 component=stage step=stage result=ok files=3\n'
printf 'unrelated journal line\n'
STUB
  printf 't1-revive-diagnostic v=1 component=preflight check=model result=ok\n' >"$T1R_LOG/a.log"
  printf 'a human-readable log line\n' >>"$T1R_LOG/a.log"
  t1r_run cmd_report
  assert_status 0
  assert_contains "$output" "diag-log: 1"
  assert_contains "$output" "diag-journal: 1"
  assert_contains "$output" "component=preflight check=model result=ok"
  assert_contains "$output" "component=stage step=stage result=ok files=3"
  refute_contains "$output" "unrelated journal line"
  refute_contains "$output" "a human-readable log line"
}

# --- options ----------------------------------------------------------------------------------
@test "report: --since with a non-numeric value exits 2" {
  report_load
  t1r_run cmd_report --since soon
  assert_status 2
  assert_contains "$output" "usage: t1-revive report"
}

@test "report: --since without a value, and an unknown flag, exit 2" {
  report_load
  t1r_run cmd_report --since
  assert_status 2
  t1r_run cmd_report --frobnicate
  assert_status 2
  t1r_run cmd_report --out
  assert_status 2
}

@test "report: --since with a number is accepted and recorded in the bundle" {
  report_load
  t1r_run cmd_report --since 15
  assert_status 0
  assert_contains "$output" "diag-since: 15"
}

@test "report: --help exits 0" {
  report_load
  t1r_run cmd_report --help
  assert_status 0
  assert_contains "$output" "usage: t1-revive report"
}

@test "sourcing lib/report.sh has no side effects" {
  t1r_run bash -c '. "$T1R_ROOT/lib/common.sh"; . "$T1R_ROOT/lib/report.sh"; echo sourced-ok'
  assert_status 0
  assert_eq "sourced-ok" "$output"
}
