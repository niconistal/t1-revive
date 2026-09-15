#!/usr/bin/env bats
# lib/discover.sh against the AGENTS.md contract, with synthetic DMI and lsblk fixtures.

load test_helper/common

setup() { t1r_env; }

@test "model_id: MacBookPro14,3 from dmi-14_3" {
  t1r_use_dmi 14_3; t1r_load discover; t1r_need model_id
  assert_eq "MacBookPro14,3" "$(model_id)"
}

@test "model_id: MacBookPro13,2 from dmi-13_2 and 'Not a Mac' from dmi-other" {
  t1r_use_dmi 13_2; t1r_load discover; t1r_need model_id
  assert_eq "MacBookPro13,2" "$(model_id)"
  t1r_use_dmi other
  assert_eq "Not a Mac" "$(model_id)"
}

@test "model_status: MacBookPro14,3 -> tested" {
  t1r_load discover; t1r_need model_status
  assert_eq tested "$(model_status MacBookPro14,3)"
}

@test "model_status: MacBookPro13,2 -> untested" {
  t1r_load discover; t1r_need model_status
  assert_eq untested "$(model_status MacBookPro13,2)"
}

@test "model_status: MacBookPro13,3 and MacBookPro14,2 -> untested" {
  t1r_load discover; t1r_need model_status
  assert_eq untested "$(model_status MacBookPro13,3)"
  assert_eq untested "$(model_status MacBookPro14,2)"
}

@test "model_status: MacBookPro15,1 (T2) -> unsupported" {
  t1r_load discover; t1r_need model_status
  assert_eq unsupported "$(model_status MacBookPro15,1)"
}

@test "model_status: 'Not a Mac' -> unsupported" {
  t1r_load discover; t1r_need model_status
  assert_eq unsupported "$(model_status "Not a Mac")"
}

@test "esp_candidates: one ESP -> one line with /dev/sdz1" {
  t1r_use_lsblk one-esp; t1r_load discover; t1r_need esp_candidates
  local out; out=$(esp_candidates)
  assert_eq 1 "$(printf '%s\n' "$out" | grep -c .)" "line count"
  assert_contains "$out" "/dev/sdz1"
  refute_contains "$out" "/dev/sdz2"
}

@test "esp_candidates: two ESPs -> two lines, three columns each" {
  t1r_use_lsblk two-esp; t1r_load discover; t1r_need esp_candidates
  local out; out=$(esp_candidates)
  assert_eq 2 "$(printf '%s\n' "$out" | grep -c .)" "line count"
  assert_contains "$out" "/dev/sdz1"
  assert_contains "$out" "/dev/sdy1"
  while read -r dev mp has; do
    [[ -n $dev && -n $mp && -n $has ]] || { echo "bad line: '$dev $mp $has'" >&2; return 1; }
  done <<<"$out"
}

@test "esp_candidates: no ESP -> no output" {
  t1r_use_lsblk no-esp; t1r_load discover; t1r_need esp_candidates
  assert_eq "" "$(esp_candidates)"
}

@test "esp_select: one ESP -> selected" {
  t1r_use_lsblk one-esp; t1r_load discover; t1r_need esp_select
  run esp_select
  assert_status 0
  [[ $output == /dev/sdz1\ * || $output == /dev/sdz1 ]] || { echo "got: $output" >&2; return 1; }
}

@test "esp_select: two ESPs, neither distinguished -> returns 1" {
  t1r_use_lsblk two-esp; t1r_load discover; t1r_need esp_select
  run esp_select
  assert_status 1
}

@test "esp_select: two ESPs, one has EFI/APPLE -> that one" {
  t1r_load discover; t1r_need esp_select
  local mnt=$T1R_TMP/esp2
  mkdir -p "$mnt/EFI/APPLE"
  sed "s|@ESP_MNT@|$mnt|" "$T1R_FIXTURES/lsblk-two-esp-apple.json.tmpl" >"$T1R_TMP/lsblk.json"
  export T1R_LSBLK_JSON=$T1R_TMP/lsblk.json
  run esp_select
  assert_status 0
  assert_contains "$output" "/dev/sdy1"
}

@test "esp_select: two ESPs, one mounted at /boot -> that one" {
  t1r_use_lsblk two-esp-boot; t1r_load discover; t1r_need esp_select
  run esp_select
  assert_status 0
  assert_contains "$output" "/dev/sdz1"
}

@test "esp_select: two ESPs, one at /boot without EFI/APPLE, the other mounted with it -> the Apple one" {
  # A Linux install next to macOS: the distro's ESP is at /boot, Apple's is the other one.
  t1r_fake_esp lsblk-two-esp-boot-apple; t1r_esp_apple_data; t1r_load discover; t1r_need esp_select
  run esp_select
  assert_status 0
  assert_contains "$output" "/dev/sdy1"
  run esp_select --why
  assert_contains "$output" "holds EFI/APPLE"
}

@test "esp_select: an EFI/APPLE on a removable disk does not beat the ESP at /boot" {
  t1r_fake_esp lsblk-two-esp-boot-apple; t1r_esp_apple_data; t1r_load discover; t1r_need esp_select
  mkdir -p "$T1R_TMP/sys/block/sdy"; echo 1 >"$T1R_TMP/sys/block/sdy/removable"
  export T1R_SYSFS=$T1R_TMP/sys
  run esp_select
  assert_status 0
  assert_contains "$output" "/dev/sdz1"
  run esp_select --why
  assert_contains "$output" "mounted at /boot"
}

@test "esp_select: two ESPs both holding EFI/APPLE on internal disks -> returns 1" {
  t1r_fake_esp lsblk-two-esp-both-mounted; t1r_esp_apple_data
  mkdir -p "$T1R_TMP/esp2/EFI/APPLE"
  sed -i "s|@ESP2_MNT@|$T1R_TMP/esp2|" "$T1R_LSBLK_JSON"
  t1r_load discover; t1r_need esp_select
  run esp_select
  assert_status 1
}

@test "esp_select --why: the only ESP, and a T1R_ESP_DEV pin" {
  t1r_use_lsblk one-esp; t1r_load discover; t1r_need esp_select
  assert_eq "the only EFI system partition" "$(esp_select --why)"
  t1r_use_lsblk two-esp
  export T1R_ESP_DEV=/dev/sdy1
  run esp_select
  assert_status 0
  assert_contains "$output" "/dev/sdy1"
  assert_contains "$(esp_select --why)" "T1R_ESP_DEV"
}

@test "esp_apple_facts: five yes/no words from a mounted tree" {
  t1r_load discover; t1r_need esp_apple_facts
  mkdir -p "$T1R_TMP/m"
  assert_eq "no no no no no" "$(esp_apple_facts "$T1R_TMP/m")"
  mkdir -p "$T1R_TMP/m/EFI/APPLE/EMBEDDEDOS"
  : >"$T1R_TMP/m/EFI/APPLE/EMBEDDEDOS/FDRData"; : >"$T1R_TMP/m/EFI/APPLE/EMBEDDEDOS/version.plist"
  assert_eq "yes yes no yes yes" "$(esp_apple_facts "$T1R_TMP/m")"
}

@test "esp_with_ro_mount: T1R_ESP_PROBE=0 runs nothing and returns 1" {
  t1r_stub_mount; t1r_load discover; t1r_need esp_with_ro_mount
  export T1R_ESP_PROBE=0
  run esp_with_ro_mount /dev/sdz1 esp_apple_facts
  assert_status 1
  assert_eq "" "$output"
  [[ ! -e $T1R_TMP/mount.log ]] || { echo "mount was called" >&2; return 1; }
}

@test "esp_probe: mounts read-only, reports the facts, unmounts and removes the directory" {
  t1r_stub_mount; t1r_stub_apple_data; t1r_load discover; t1r_need esp_probe
  run esp_probe /dev/sdz1
  assert_status 0
  assert_eq "yes yes yes yes yes" "$output"
  local log; log=$(cat "$T1R_TMP/mount.log")
  assert_contains "$log" "mount -t vfat -o ro,nosuid,nodev,noexec /dev/sdz1 $T1R_TMP/t1-revive-probe."
  assert_contains "$log" "umount $T1R_TMP/t1-revive-probe."
  assert_eq "" "$(find "$T1R_TMP" -maxdepth 1 -name 't1-revive-probe.*')" "probe directory left behind"
}

@test "esp_probe: a failing mount leaves nothing behind and returns 1" {
  t1r_stub_mount; t1r_load discover; t1r_need esp_probe
  printf '#!/usr/bin/env bash\nexit 32\n' >"$T1R_TMP/bin/mount"
  run esp_probe /dev/sdz1
  assert_status 1
  assert_eq "" "$output"
  assert_eq "" "$(find "$T1R_TMP" -maxdepth 1 -name 't1-revive-probe.*')" "probe directory left behind"
}

@test "esp_candidates: an unmounted ESP is looked at through the probe" {
  t1r_stub_mount; t1r_stub_apple_data; t1r_use_lsblk two-esp-boot; t1r_load discover; t1r_need esp_candidates
  local out; out=$(esp_candidates)
  assert_contains "$out" "/dev/sdy1 - yes"
  export T1R_ESP_PROBE=0
  out=$(esp_candidates)
  assert_contains "$out" "/dev/sdy1 - ?"
}

@test "esp_select: dual-boot layout, Apple's ESP unmounted -> the probe finds it and it wins over /boot" {
  # The bug behind issue #2: /boot used to win, so backup found nothing on an intact machine.
  t1r_stub_mount; t1r_stub_apple_data; t1r_use_lsblk two-esp-boot; t1r_load discover; t1r_need esp_select
  run esp_select
  assert_status 0
  assert_contains "$output" "/dev/sdy1"
  export T1R_ESP_PROBE=0
  run esp_select
  assert_status 0
  assert_contains "$output" "/dev/sdz1"
}

@test "esp_select: no ESP -> returns 1" {
  t1r_use_lsblk no-esp; t1r_load discover; t1r_need esp_select
  run esp_select
  assert_status 1
}

@test "frst_method: empty (not an error) when there are no ACPI tables" {
  t1r_load discover; t1r_need frst_method
  run frst_method
  assert_eq "" "$output"
}

@test "sourcing lib/discover.sh has no side effects" {
  [[ -f $T1R_REPO/lib/discover.sh ]] || skip "lib/discover.sh not present"
  run bash -c 'source "$T1R_ROOT/lib/common.sh"; source "$T1R_ROOT/lib/discover.sh"; echo sourced-ok'
  assert_status 0
  assert_eq "sourced-ok" "$output"
}
