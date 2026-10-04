#!/usr/bin/env bats
# lib/cmd-handover.sh: the Touch ID advice handover prints after giving the T1 to t1bridge.
#
# Only the pure helpers are exercised here; cmd_handover itself needs root and a live T1.
# lib/steps/common-steps.sh defines `run`, so the suite uses t1r_run (test_helper/common).

load test_helper/common

setup() {
  t1r_env
  t1r_load discover steps/common-steps cmd-handover
  t1r_need handover_touchid_advice handover_embeddedos_dir
}

@test "handover advice: a ready keybag keeps the enrolment and prints no import" {
  t1r_run handover_touchid_advice $'drm: ready\nkeybag: ready\nbroker: ready' /boot/EFI/APPLE/EMBEDDEDOS
  [ "$status" -eq 0 ]
  assert_contains "$output" "existing enrolment stays valid"
  [[ $output != *"machine-data import"* ]]
}

@test "handover advice: a keybag that is not ready gets the explicit import against the staged set (t1bridge#29)" {
  t1r_run handover_touchid_advice $'drm: ready\nkeybag: not-enrolled' /boot/EFI/APPLE/EMBEDDEDOS
  [ "$status" -eq 0 ]
  assert_contains "$output" "sudo t1bridge machine-data import --from /boot/EFI/APPLE/EMBEDDEDOS"
  assert_contains "$output" "fprintd-enroll"
  assert_contains "$output" "t1bridge#29"
}

@test "handover advice: no status at all still gets the import, with a placeholder path" {
  t1r_run handover_touchid_advice "" ""
  [ "$status" -eq 0 ]
  assert_contains "$output" "machine-data import --from <ESP mount>/EFI/APPLE/EMBEDDEDOS"
}

@test "handover_embeddedos_dir: prefers the ESP a regenerate run resolved" {
  mkdir -p "$T1R_TMP/esp/EFI/APPLE/EMBEDDEDOS"
  ESP_MNT=$T1R_TMP/esp t1r_run handover_embeddedos_dir
  [ "$status" -eq 0 ]
  [ "$output" = "$T1R_TMP/esp/EFI/APPLE/EMBEDDEDOS" ]
}

@test "handover_embeddedos_dir: a resolved ESP without the set is skipped, never invented" {
  mkdir -p "$T1R_TMP/empty-esp"
  ESP_MNT=$T1R_TMP/empty-esp t1r_run handover_embeddedos_dir
  [ "$status" -eq 0 ]
  [[ $output != "$T1R_TMP/empty-esp"* ]]
}
