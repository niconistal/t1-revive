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

@test "model_status: MacBookPro13,2 -> tested (a confirmed cold boot, issue #9)" {
  t1r_load discover; t1r_need model_status
  assert_eq tested "$(model_status MacBookPro13,2)"
}

@test "model_status: every model of the allowlist is tested, and nothing else is accepted" {
  t1r_load discover; t1r_need model_status
  local m
  for m in $T1R_TESTED_MODELS; do assert_eq tested "$(model_status "$m")"; done
  assert_eq '' "$T1R_UNTESTED_MODELS"
  assert_eq unsupported "$(model_status MacBookPro15,1)"
  assert_eq unsupported "$(model_status '')"
}

@test "model_status: a model on the untested list warns instead of being refused" {
  t1r_load discover; t1r_need model_status
  T1R_TESTED_MODELS="MacBookPro14,3" T1R_UNTESTED_MODELS="MacBookPro13,2"
  assert_eq untested "$(model_status MacBookPro13,2)"
  assert_eq tested "$(model_status MacBookPro14,3)"
}

@test "model_status: MacBookPro13,3 and MacBookPro14,2 -> tested (one confirmed regeneration each, issues #4 and #5)" {
  t1r_load discover; t1r_need model_status
  assert_eq tested "$(model_status MacBookPro13,3)"
  assert_eq tested "$(model_status MacBookPro14,2)"
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

@test "esp_release: unmounts the tool's own mount directory even when esp_mount ran in a subshell" {
  # esp_mount is called as $(esp_mount ...), so T1R_ESP_MOUNTED never reaches the exiting shell.
  t1r_stub_mount; t1r_load discover; t1r_need esp_release
  t1r_stub_bin findmnt <<STUB
#!/usr/bin/env bash
[[ "\${*: -1}" = "$T1R_STATE/esp" ]] && { echo "$T1R_STATE/esp"; exit 0; }
exit 1
STUB
  mkdir -p "$T1R_STATE/esp"
  unset T1R_ESP_MOUNTED
  run esp_release
  assert_status 0
  assert_contains "$(cat "$T1R_TMP/mount.log")" "umount $T1R_STATE/esp"
}

@test "esp_probe: a failing unmount warns with the commands to run and keeps the directory" {
  t1r_stub_mount; t1r_stub_apple_data; t1r_load discover; t1r_need esp_probe
  printf '#!/usr/bin/env bash\nexit 1\n' >"$T1R_TMP/bin/umount"
  run esp_probe /dev/sdz1
  assert_status 0
  assert_contains "$output" "run: umount $T1R_TMP/t1-revive-probe."
  [[ -n "$(find "$T1R_TMP" -maxdepth 1 -name 't1-revive-probe.*')" ]] || { echo "the probe directory was removed while something may be mounted on it" >&2; return 1; }
}

@test "esp_select --why: as a normal user the /boot fallback is provisional (issue #2)" {
  # Without root the unmounted ESP stays '?', so the /boot rule wins by default; the why-line
  # must say so instead of stating the /boot reason as a fact.
  t1r_use_lsblk two-esp-boot; t1r_load discover; t1r_need esp_select
  export T1R_ESP_PROBE=0
  run esp_select --why
  assert_status 0
  assert_contains "$output" "mounted at /boot"
  # the real /boot is usually mode 0700, so as a normal user it counts as unlooked-at too
  [[ "$output" =~ provisional:\ [12]\ EFI\ system\ partition\(s\)\ could\ not\ be\ looked\ inside ]] || { echo "not marked provisional: $output" >&2; return 1; }
  [[ "${EUID:-$(id -u)}" = 0 ]] || assert_contains "$output" "run as root to be sure"
}

@test "esp_select --why: the /boot fallback is definite once every ESP was looked inside" {
  # the fixture's mounted ESP is the real /boot; this user must be able to look inside it
  [[ -r /boot ]] && [[ -x /boot ]] || skip "/boot is not readable as this user"
  t1r_stub_mount; t1r_use_lsblk two-esp-boot; t1r_load discover; t1r_need esp_select
  run esp_select --why
  assert_status 0
  assert_contains "$output" "mounted at /boot, and no EFI system partition is known to hold EFI/APPLE"
  refute_contains "$output" "provisional"
}

# findmnt as esp_mount sees it: nothing is mounted anywhere, and whatever the tool mounted is vfat.
esp_stub_findmnt() {
  t1r_stub_bin findmnt <<'STUB'
#!/usr/bin/env bash
case "$*" in *FSTYPE*) echo vfat;; *) exit 1;; esac
STUB
}

@test "esp_mount: 'ro' mounts read-only with nosuid,nodev,noexec under the state directory (issue #2)" {
  t1r_stub_mount; t1r_stub_apple_data; t1r_use_lsblk one-esp; t1r_load discover; t1r_need esp_mount
  esp_stub_findmnt
  export T1R_DRY_RUN=0
  run esp_mount /dev/sdz1 ro
  assert_status 0
  assert_eq "$T1R_STATE/esp" "$output"
  assert_contains "$(cat "$T1R_TMP/mount.log")" "mount -t vfat -o ro,nosuid,nodev,noexec /dev/sdz1 $T1R_STATE/esp"
  [[ -f $T1R_STATE/esp/EFI/APPLE/EMBEDDEDOS/FDRData ]]
}

@test "esp_mount: without 'ro' the mount is read-write (stage writes to it)" {
  t1r_stub_mount; t1r_use_lsblk one-esp; t1r_load discover; t1r_need esp_mount
  esp_stub_findmnt
  export T1R_DRY_RUN=0
  run esp_mount /dev/sdz1
  assert_status 0
  assert_contains "$(cat "$T1R_TMP/mount.log")" "mount -t vfat /dev/sdz1 $T1R_STATE/esp"
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

# --- leftovers of older Touch Bar stacks (issue #10) -----------------------------------------
# lsmod and dkms are stubbed so the answer never depends on the machine running the suite, and
# the udev directories are fixtures. The live-machine case (a clean 14,3 with t1bridge loaded)
# must stay clean: appletbdrm, apple_t1_ncm and t1_cfgsel are t1bridge's own and are not
# leftovers.
legacy_env() {
  t1r_load discover
  t1r_need legacy_t1_stack
  export T1R_UDEV_RULES_DIRS=$T1R_TMP/udev T1R_PKG_UDEV_RULES_DIRS=$T1R_TMP/udev-pkg
  mkdir -p "$T1R_UDEV_RULES_DIRS" "$T1R_PKG_UDEV_RULES_DIRS"
  t1r_stub_bin lsmod <<'STUB'
#!/usr/bin/env bash
cat "${T1R_STUB_LSMOD:-/dev/null}" 2>/dev/null || true
STUB
  t1r_stub_bin dkms <<'STUB'
#!/usr/bin/env bash
cat "${T1R_STUB_DKMS:-/dev/null}" 2>/dev/null || true
STUB
  export T1R_STUB_LSMOD=$T1R_TMP/lsmod.txt T1R_STUB_DKMS=$T1R_TMP/dkms.txt
  : >"$T1R_STUB_LSMOD"; : >"$T1R_STUB_DKMS"
}

@test "legacy_t1_stack: a clean machine prints nothing and returns 1" {
  legacy_env
  run legacy_t1_stack
  assert_status 1
  assert_eq '' "$output"
}

@test "legacy_t1_stack: t1bridge's own modules are not leftovers" {
  legacy_env
  printf 'appletbdrm 24576 1
apple_t1_ncm 12288 0
t1_cfgsel 12288 0
cdc_ncm 53248 2
' >"$T1R_STUB_LSMOD"
  run legacy_t1_stack
  assert_status 1
  assert_eq '' "$output"
}

@test "legacy_t1_stack: a loaded legacy module is reported" {
  legacy_env
  printf 'apple_ibridge 20480 2 apple_ib_tb
apple_ib_tb 16384 0
' >"$T1R_STUB_LSMOD"
  run legacy_t1_stack
  assert_status 0
  assert_contains "$output" 'module apple_ibridge'
  assert_contains "$output" 'module apple_ib_tb'
}

@test "legacy_t1_stack: a DKMS build counts even when the module is not loaded" {
  legacy_env
  printf 'apple-ib-drv/0.1, 7.2.3-arch1-3, x86_64: installed
' >"$T1R_STUB_DKMS"
  run legacy_t1_stack
  assert_status 0
  assert_contains "$output" 'dkms apple-ib-drv'
  refute_contains "$output" 'module '
}

@test "legacy_t1_stack: an unrelated DKMS package is left alone" {
  legacy_env
  printf 'acpi_call/1.2.2, 7.2.3-arch1-3, x86_64: installed
t1bridge/0.1.9, 7.2.3-arch1-3, x86_64: installed
' >"$T1R_STUB_DKMS"
  run legacy_t1_stack
  assert_status 1
  assert_eq '' "$output"
}

@test "legacy_t1_stack: a loaded module and its DKMS package are both reported" {
  legacy_env
  printf 'apple_ibridge 20480 0
' >"$T1R_STUB_LSMOD"
  printf 'apple-ib-drv/0.1, 7.2.3-arch1-3, x86_64: installed
' >"$T1R_STUB_DKMS"
  run legacy_t1_stack
  assert_status 0
  assert_contains "$output" 'module apple_ibridge'
  assert_contains "$output" 'dkms apple-ib-drv'
}

@test "legacy_t1_stack: a udev rule pinning the T1's configuration is reported" {
  legacy_env
  cat >"$T1R_UDEV_RULES_DIRS/99-ibridge.rules" <<'RULE'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", ATTR{idProduct}=="8600", ATTR{bConfigurationValue}="1"
RULE
  run legacy_t1_stack
  assert_status 0
  assert_contains "$output" 'udev '
  assert_contains "$output" '99-ibridge.rules'
}

@test "legacy_t1_stack: a configuration pin for some other device is left alone" {
  legacy_env
  cat >"$T1R_UDEV_RULES_DIRS/50-other.rules" <<'RULE'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="1234", ATTR{idProduct}=="5678", ATTR{bConfigurationValue}="2"
RULE
  run legacy_t1_stack
  assert_status 1
  assert_eq '' "$output"
}

@test "legacy_t1_stack: a T1 rule that does not pin a configuration is left alone" {
  legacy_env
  cat >"$T1R_UDEV_RULES_DIRS/90-t1bridge-xart.rules" <<'RULE'
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", ATTR{idProduct}=="8600", TAG+="uaccess"
RULE
  run legacy_t1_stack
  assert_status 1
  assert_eq '' "$output"
}

@test "legacy_t1_stack: a missing rules directory is not an error" {
  legacy_env
  export T1R_UDEV_RULES_DIRS=$T1R_TMP/does-not-exist T1R_PKG_UDEV_RULES_DIRS=$T1R_TMP/does-not-exist-either
  run legacy_t1_stack
  assert_status 1
  assert_eq '' "$output"
}

# --- packaged rules (usbmuxd's 39-usbmuxd.rules) ---------------------------------------------
# usbmuxd ships a rule in /usr/lib/udev/rules.d that sets bConfigurationValue=1 on 05ac:8600
# add. After a regeneration that returns the T1 to configuration 1 and t1bridge stays at
# usb-configuration: unexpected (standardagents/t1bridge#64). The same file also pins iPhones,
# and t1bridge's own packaged rules mention 8600 without pinning anything.
usbmuxd_rules() {  # the shape of usbmuxd's rule file, with or without its 8600 lines
  printf '%s\n' \
    '# usbmuxd (Apple Mobile Device Muxer)' \
    'SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{PRODUCT}=="5ac/12[9a][0-9a-f]/*|5ac/8600/*", TAG+="systemd"' \
    'SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{PRODUCT}=="5ac/12[9a][0-9a-f]/*", ACTION=="add", ATTR{bConfigurationValue}="0", OWNER="usbmux"'
  [[ ${1:-} == with-t1 ]] && printf '%s\n' \
    'SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{PRODUCT}=="5ac/8600/*", ACTION=="add", ATTR{bConfigurationValue}="1", OWNER="usbmux"'
  return 0
}

@test "legacy_t1_stack: a packaged rule pinning 05ac:8600 is reported as udev-pkg" {
  legacy_env
  usbmuxd_rules with-t1 >"$T1R_PKG_UDEV_RULES_DIRS/39-usbmuxd.rules"
  run legacy_t1_stack
  assert_status 0
  assert_contains "$output" "udev-pkg $T1R_PKG_UDEV_RULES_DIRS/39-usbmuxd.rules"
}

@test "legacy_t1_stack: a packaged rule overridden in an admin directory is left alone" {
  legacy_env
  usbmuxd_rules with-t1 >"$T1R_PKG_UDEV_RULES_DIRS/39-usbmuxd.rules"
  { echo '# override: same rules without the Apple T1 (05ac:8600) lines'; usbmuxd_rules; } \
    >"$T1R_UDEV_RULES_DIRS/39-usbmuxd.rules"
  run legacy_t1_stack
  assert_status 1
  assert_eq '' "$output"
}

@test "legacy_t1_stack: iPhone pins next to an unpinned 8600 match are left alone" {
  legacy_env
  usbmuxd_rules >"$T1R_PKG_UDEV_RULES_DIRS/39-usbmuxd.rules"
  run legacy_t1_stack
  assert_status 1
  assert_eq '' "$output"
}

@test "legacy_t1_stack: t1bridge's packaged rules are never reported" {
  legacy_env
  cat >"$T1R_PKG_UDEV_RULES_DIRS/99-zz-t1bridge-touchbar.rules" <<'RULE'
ACTION=="add|change", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", \
  SUBSYSTEMS=="usb", ATTRS{idVendor}=="05ac", ATTRS{idProduct}=="8600", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}="t1-touchbar-hw.service"
RULE
  run legacy_t1_stack
  assert_status 1
  assert_eq '' "$output"
}

@test "legacy_t1_stack: a T1 pin split across continuation lines is still reported" {
  legacy_env
  cat >"$T1R_UDEV_RULES_DIRS/99-ibridge.rules" <<'RULE'
ACTION=="add", SUBSYSTEM=="usb", \
  ATTR{idVendor}=="05ac", ATTR{idProduct}=="8600", \
  ATTR{bConfigurationValue}="1"
RULE
  run legacy_t1_stack
  assert_status 0
  assert_contains "$output" 'udev '
}
