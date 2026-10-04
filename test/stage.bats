#!/usr/bin/env bats
# lib/cmd-stage.sh: the boot-marker gate, the ESP selection and the dry run.
#
# The "ESP" is a directory under $T1R_TMP that a synthetic lsblk fixture points at, so
# esp_select/esp_resolve run for real without a block device. require_root and firmware_ensure
# are redefined AFTER sourcing. The only test that runs with T1R_DRY_RUN=0 is the one that must
# be refused before anything is written.
#
# Note: lib/steps/common-steps.sh defines a function called `run`, which shadows bats' own
# `run` helper; the suite keeps a copy of it as t1r_run (see test/test_helper/common.bash).

load test_helper/common

setup() {
  t1r_env
  [[ -f $T1R_REPO/lib/cmd-stage.sh ]] || skip "lib/cmd-stage.sh not present"
  t1r_use_sysfs booted-cfg1
  t1r_stub_prefix
  mkdir -p "$T1R_TMP/fw"
}

stage_load() {
  t1r_load discover cmd-stage
  t1r_need cmd_stage
  require_root() { :; }
  firmware_ensure() { printf '%s\n' "$T1R_TMP/fw"; }
}

# --- arguments -----------------------------------------------------------------------------
@test "stage: an unknown flag exits 2" {
  stage_load
  t1r_run cmd_stage --frobnicate
  assert_status 2
  assert_contains "$output" "usage: t1-revive stage"
}

# --- the boot-marker gate --------------------------------------------------------------------
@test "stage: refuses with exit 4 when the boot step never completed" {
  export T1R_DRY_RUN=0
  t1r_fake_esp; t1r_esp_apple_data; t1r_esp_snapshot; stage_load
  t1r_run cmd_stage
  assert_status 4
  assert_contains "$output" "the boot step has not completed"
  assert_contains "$output" "--force"
  t1r_esp_unchanged
}

@test "stage: a dry run without the boot marker says a real run would refuse" {
  t1r_fake_esp; t1r_esp_snapshot; stage_load
  t1r_run cmd_stage
  assert_status 0
  assert_contains "$output" "(dry) no boot marker: a real run would refuse here"
  t1r_esp_unchanged
}

@test "stage: --force warns instead of refusing when the marker is missing" {
  t1r_fake_esp; t1r_esp_snapshot; stage_load
  t1r_run cmd_stage --dry-run --force
  assert_status 0
  assert_contains "$output" "--force given, staging anyway"
  t1r_esp_unchanged
}

# --- the dry run -------------------------------------------------------------------------
@test "stage: with the boot marker a dry run lists the writes and writes nothing" {
  t1r_fake_esp; t1r_esp_snapshot; t1r_step_marker boot; stage_load
  t1r_run cmd_stage
  assert_status 0
  assert_contains "$output" "*** DRY RUN: nothing will be written ***"
  refute_contains "$output" "a real run would refuse here"
  local f
  for f in combined.memboot FDRData version.plist; do
    assert_contains "$output" "(dry) install -m 644"
    assert_contains "$output" "$T1R_ESP_MNT/EFI/APPLE/EMBEDDEDOS/$f"
  done
  assert_contains "$output" "(dry) mv -f"
  assert_contains "$output" "(dry) sync"
  # the verify pass is the only thing that reads back, and a dry run skips it
  assert_contains "$output" "(dry) skipped"
  refute_contains "$output" "verified"
  t1r_esp_unchanged
  [[ ! -e $T1R_ESP_MNT/EFI/APPLE/EMBEDDEDOS ]] || {
    echo "the dry run created EFI/APPLE/EMBEDDEDOS" >&2; return 1; }
}

@test "stage: a dry run keeps a copy of existing files under private/esp-backup-<stamp>" {
  t1r_fake_esp; t1r_esp_apple_data; t1r_esp_snapshot; t1r_step_marker boot; stage_load
  t1r_run cmd_stage
  assert_status 0
  assert_contains "$output" "backing up FDRData -> private/esp-backup-"
  assert_contains "$output" "backing up version.plist -> private/esp-backup-"
  assert_contains "$output" "(dry) install -d -m 700 $T1R_STATE/private/esp-backup-"
  t1r_esp_unchanged
  [[ -z $(find "$T1R_STATE/private" -name 'esp-backup-*' 2>/dev/null || true) ]] || {
    echo "the dry run really copied the ESP files" >&2; return 1; }
}

# --- ESP selection ---------------------------------------------------------------------------
@test "stage: selects the single unmounted ESP through esp_select and would mount it" {
  t1r_use_lsblk one-esp; t1r_step_marker boot; stage_load
  t1r_run cmd_stage
  assert_status 0
  assert_contains "$output" "(dry-run) mount /dev/sdz1 $T1R_STATE/esp"
  assert_contains "$output" "$T1R_STATE/esp/EFI/APPLE/EMBEDDEDOS/combined.memboot"
}

@test "stage: picks the ESP that holds EFI/APPLE when there are two" {
  t1r_fake_esp lsblk-two-esp-apple; t1r_esp_apple_data; t1r_esp_snapshot
  t1r_step_marker boot; stage_load
  t1r_run cmd_stage
  assert_status 0
  # /dev/sdy1 is the fixture's second ESP: the one mounted where EFI/APPLE lives
  assert_contains "$output" "$T1R_ESP_MNT/EFI/APPLE/EMBEDDEDOS"
  refute_contains "$output" "/dev/sdz1 "
  t1r_esp_unchanged
}

@test "stage: refuses with exit 4 when two ESPs are indistinguishable" {
  t1r_use_lsblk two-esp; t1r_step_marker boot; stage_load
  t1r_run cmd_stage
  assert_status 4
  assert_contains "$output" "cannot identify a single EFI System Partition"
}

@test "stage: refuses with exit 4 when there is no ESP at all" {
  t1r_use_lsblk no-esp; t1r_step_marker boot; stage_load
  t1r_run cmd_stage
  assert_status 4
  assert_contains "$output" "cannot identify a single EFI System Partition"
}

@test "sourcing lib/cmd-stage.sh has no side effects" {
  t1r_run bash -c '. "$T1R_ROOT/lib/common.sh"; . "$T1R_ROOT/lib/discover.sh"
                   . "$T1R_ROOT/lib/cmd-stage.sh"; echo sourced-ok'
  assert_status 0
  assert_eq "sourced-ok" "$output"
}

# --- two-phase write ---------------------------------------------------------------------------
@test "stage: a dry run writes all three temporary files before the first rename, memboot last" {
  t1r_fake_esp; t1r_esp_snapshot; t1r_step_marker boot; stage_load
  t1r_run cmd_stage
  assert_status 0
  local lines last_install first_mv last_mv
  lines=$(printf '%s\n' "$output" | grep -nE '\(dry\) (install -m 644|mv -f)')
  last_install=$(printf '%s\n' "$lines" | grep 'install -m 644' | tail -1 | cut -d: -f1)
  first_mv=$(printf '%s\n' "$lines" | grep 'mv -f' | head -1 | cut -d: -f1)
  last_mv=$(printf '%s\n' "$lines" | grep 'mv -f' | tail -1)
  [ -n "$last_install" ] && [ -n "$first_mv" ]
  [ "$last_install" -lt "$first_mv" ] || { echo "a rename came before the last write" >&2; return 1; }
  [[ $last_mv == *"/combined.memboot" ]] || { echo "combined.memboot is not renamed last: $last_mv" >&2; return 1; }
  t1r_esp_unchanged
}

@test "stage_leftovers: names the temporary files an interrupted stage left, and nothing otherwise" {
  stage_load
  local esp=$T1R_TMP/eos; mkdir -p "$esp"
  [ -z "$(stage_leftovers "$esp")" ]
  : > "$esp/.FDRData.new"; : > "$esp/.combined.memboot.new"
  [ "$(stage_leftovers "$esp")" = ".combined.memboot.new .FDRData.new" ]
}
