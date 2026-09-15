#!/usr/bin/env bats
# lib/cmd-backup.sh: the tar of the ESP's EFI/APPLE tree, its mode, its sidecar and its copy.
#
# The "ESP" is a directory under $T1R_TMP that a synthetic lsblk fixture points at, so
# esp_select and esp_mount run for real without a block device and without mount(8). The file
# contents are obviously synthetic placeholders - no device data ever goes near this suite.
# Only require_root is stubbed, after sourcing.

load test_helper/common

setup() {
  t1r_env
  [[ -f $T1R_REPO/lib/cmd-backup.sh ]] || skip "lib/cmd-backup.sh not present"
  t1r_use_sysfs recovery
  # the marker string the tests look for: it must never reach the terminal
  T1R_TEST_SECRET=SYNTHETIC-FDR-PLACEHOLDER-NOT-DEVICE-DATA
}

backup_load() {
  t1r_load discover cmd-backup
  t1r_need cmd_backup
  require_root() { :; }
}

# --- a populated ESP --------------------------------------------------------------------------
@test "backup: writes a 0600 tar with EFI/APPLE inside, plus a sha256 sidecar" {
  export T1R_DRY_RUN=0
  t1r_fake_esp; t1r_esp_apple_data; t1r_esp_snapshot; backup_load
  run cmd_backup
  assert_status 0

  local tar; tar=$(find "$T1R_STATE" -maxdepth 1 -type f -name 'efi-backup-*.tar' | head -1)
  [[ -n $tar ]] || { echo "no efi-backup-*.tar under $T1R_STATE" >&2; return 1; }
  assert_eq 600 "$(stat -c %a "$tar")" "tar mode"
  assert_eq 600 "$(stat -c %a "$tar.sha256")" "sidecar mode"

  local listing; listing=$(tar -tf "$tar" | sort)
  assert_contains "$listing" "EFI/APPLE/EMBEDDEDOS/FDRData"
  assert_contains "$listing" "EFI/APPLE/EMBEDDEDOS/version.plist"

  # the sidecar holds the real checksum of the real tar
  assert_eq "$(sha256sum "$tar" | awk '{print $1}')  ${tar##*/}" "$(cat "$tar.sha256")"
  # and the tool printed the first 12 characters of it, which redaction leaves alone
  assert_contains "$output" "sha256 starts $(sha256sum "$tar" | cut -c1-12)"
  [[ -L $T1R_STATE/efi-backup-latest.tar ]] || { echo "no efi-backup-latest.tar symlink" >&2; return 1; }
  assert_contains "$output" "contains FDRData: yes"
  t1r_esp_unchanged
}

@test "backup: never prints the content of the files it saves" {
  export T1R_DRY_RUN=0
  t1r_fake_esp; t1r_esp_apple_data; backup_load
  run cmd_backup
  assert_status 0
  refute_contains "$output" "$T1R_TEST_SECRET"
  # and the full checksum is redacted on the way to the screen and the log
  local tar sum
  tar=$(find "$T1R_STATE" -maxdepth 1 -type f -name 'efi-backup-*.tar' | head -1)
  sum=$(sha256sum "$tar" | awk '{print $1}')
  refute_contains "$output" "$sum"
  refute_contains "$(cat "$T1R_LOG"/*.log)" "$T1R_TEST_SECRET"
}

@test "backup: --to copies the tar and its sidecar off the state directory and verifies them" {
  export T1R_DRY_RUN=0
  t1r_fake_esp; t1r_esp_apple_data; backup_load
  local to=$T1R_TMP/stick
  run cmd_backup --to "$to"
  assert_status 0
  local tar copy
  tar=$(find "$T1R_STATE" -maxdepth 1 -type f -name 'efi-backup-*.tar' | head -1)
  copy=$to/${tar##*/}
  [[ -f $copy ]] || { echo "no copy at $copy" >&2; return 1; }
  cmp -s "$tar" "$copy" || { echo "the copy differs from the original" >&2; return 1; }
  [[ -f $copy.sha256 ]] || { echo "no sidecar next to the copy" >&2; return 1; }
  assert_eq 600 "$(stat -c %a "$copy")" "copy mode"
  assert_contains "$output" "copy verified at $copy"
  assert_contains "$output" "copy written to $to"
  refute_contains "$output" "$T1R_TEST_SECRET"
}

@test "backup: records a diagnostic line with the file count" {
  export T1R_DRY_RUN=0
  t1r_fake_esp; t1r_esp_apple_data; backup_load
  run cmd_backup
  assert_status 0
  assert_contains "$(t1r_diag_lines)" "step=backup result=ok apple=present files=2"
}

# --- a wiped ESP --------------------------------------------------------------------------------
@test "backup: the only ESP without EFI/APPLE exits 1 and says nothing was backed up" {
  export T1R_DRY_RUN=0
  t1r_fake_esp; t1r_esp_snapshot; backup_load
  run cmd_backup
  assert_status 1
  assert_contains "$output" "nothing to back up"
  assert_contains "$output" "nothing was backed up"
  assert_eq "" "$(find "$T1R_STATE" -maxdepth 1 -name 'efi-backup-*' || true)"
  assert_contains "$(t1r_diag_lines)" "step=backup result=none apple=absent"
  t1r_esp_unchanged
}

@test "backup: an empty ESP next to another internal ESP is refused with exit 4 (issue #2)" {
  # The pinned partition is empty and the machine has a second internal ESP: exit 0 here
  # would tell the owner of an intact Mac there is nothing to save.
  export T1R_DRY_RUN=0
  t1r_fake_esp lsblk-two-esp-both-mounted; t1r_esp_snapshot
  mkdir -p "$T1R_TMP/esp2"; sed -i "s|@ESP2_MNT@|$T1R_TMP/esp2|" "$T1R_LSBLK_JSON"
  export T1R_ESP_DEV=/dev/sdz1
  backup_load
  run cmd_backup
  assert_status 4
  assert_contains "$output" "Nothing was backed up"
  assert_contains "$output" "/dev/sdy1"
  assert_contains "$output" "T1R_ESP_DEV"
  assert_eq "" "$(find "$T1R_STATE" -maxdepth 1 -name 'efi-backup-*' || true)"
  assert_contains "$(t1r_diag_lines)" "step=backup result=error code=4 apple=absent"
  t1r_esp_unchanged
}

@test "backup: dual-boot layout, the Apple ESP is chosen over the one at /boot" {
  export T1R_DRY_RUN=0
  t1r_fake_esp lsblk-two-esp-boot-apple; t1r_esp_apple_data; t1r_esp_snapshot; backup_load
  run cmd_backup
  assert_status 0
  assert_contains "$output" "ESP: /dev/sdy1 at $T1R_ESP_MNT"
  assert_contains "$output" "contains FDRData: yes"
  t1r_esp_unchanged
}

# --- the dry run ------------------------------------------------------------------------------
@test "backup: a dry run says what it would do and writes no tar" {
  t1r_fake_esp; t1r_esp_apple_data; t1r_esp_snapshot; backup_load
  run cmd_backup --to "$T1R_TMP/stick"
  assert_status 0
  assert_contains "$output" "(dry-run) tar -C $T1R_ESP_MNT -cf"
  assert_contains "$output" "(dry-run) copy to $T1R_TMP/stick/"
  assert_eq "" "$(find "$T1R_STATE" -maxdepth 1 -name 'efi-backup-*' || true)"
  [[ ! -e $T1R_TMP/stick ]] || { echo "a dry run created the copy directory" >&2; return 1; }
  t1r_esp_unchanged
}

# --- refusals --------------------------------------------------------------------------------
@test "backup: exits 4 when no single ESP can be identified" {
  export T1R_DRY_RUN=0
  t1r_use_lsblk two-esp; backup_load
  run cmd_backup
  assert_status 4
  assert_contains "$output" "no single EFI system partition"
}

@test "backup: unknown flags and a --to without a value exit 2" {
  t1r_fake_esp; backup_load
  run cmd_backup --frobnicate
  assert_status 2
  run cmd_backup --to
  assert_status 2
}

@test "backup: --help exits 0 and prints the usage" {
  t1r_fake_esp; backup_load
  run cmd_backup --help
  assert_status 0
  assert_contains "$output" "usage: t1-revive backup"
}

@test "sourcing lib/cmd-backup.sh has no side effects" {
  run bash -c '. "$T1R_ROOT/lib/common.sh"; . "$T1R_ROOT/lib/discover.sh"
               . "$T1R_ROOT/lib/cmd-backup.sh"; echo sourced-ok'
  assert_status 0
  assert_eq "sourced-ok" "$output"
}
