#!/usr/bin/env bats
# lib/cmd-preflight.sh: the ok/NO lines, the summary and the exit codes.
#
# Always with --local, so no name resolution and no TCP connection is attempted. The model,
# sysfs, ESP and os-release all come from test/fixtures; the patched stack is a directory of
# stub executables. distro_kernel_matches and distro_install are redefined after sourcing:
# the first because its answer would otherwise depend on the machine running the suite, the
# second because it is the one function here that would change the system.

load test_helper/common

setup() {
  t1r_env
  [[ -f $T1R_REPO/lib/cmd-preflight.sh ]] || skip "lib/cmd-preflight.sh not present"
  t1r_use_sysfs recovery
  t1r_use_dmi 14_3
  t1r_use_lsblk one-esp
  t1r_use_osrelease arch
  t1r_stub_prefix
}

pf_load() {
  t1r_load discover distro firmware cmd-preflight
  t1r_need cmd_preflight
  # the installed kernel matching the running one is a property of the machine, not of the code
  distro_kernel_matches() { return 0; }
  # so is whether this machine carries an old Touch Bar stack; the dedicated tests override it
  legacy_t1_stack() { return 1; }
  # nothing in this suite may install a package
  T1R_TEST_INSTALLS=$T1R_TMP/installs.log
  : >"$T1R_TEST_INSTALLS"
  distro_install() { printf '%s\n' "$*" >>"$T1R_TEST_INSTALLS"; return 0; }
}

# --- the normal run ---------------------------------------------------------------------------
@test "preflight --local: prints ok and NO lines and a summary, and exits 3" {
  pf_load
  run cmd_preflight --local
  assert_status 3
  printf '%s\n' "$output" | grep -q '^  ok  ' || { echo "no ok lines" >&2; return 1; }
  printf '%s\n' "$output" | grep -q '^  NO  ' || { echo "no NO lines" >&2; return 1; }
  printf '%s\n' "$output" | grep -qE '^[0-9]+ ok, [0-9]+ problems$' || {
    echo "no summary line" >&2; return 1; }
  assert_contains "$output" "Fix the NO lines first."
  assert_contains "$(t1r_diag_lines)" "step=preflight result=error code=3"
}

@test "preflight --local: skips the network checks entirely" {
  pf_load
  run cmd_preflight --local
  assert_status 3
  assert_contains "$output" "network checks skipped (--local)"
  refute_contains "$output" "gs.apple.com"
  refute_contains "$output" "swcdn.apple.com"
}

@test "preflight --local: reports the fixture model, T1 state and ESP" {
  pf_load
  run cmd_preflight --local
  assert_status 3
  assert_contains "$output" "model MacBookPro14,3 (the proven machine)"
  assert_contains "$output" "T1 in recovery (05ac:1281)"
  assert_contains "$output" "/dev/sdz1"
}

@test "preflight --local: an untested model is an ok line with a warning" {
  t1r_use_dmi 13_2; pf_load
  # 13,2 is a tested model since issue #9; the fixture stands in for the next new one
  T1R_TESTED_MODELS="MacBookPro14,3" T1R_UNTESTED_MODELS="MacBookPro13,2"
  run cmd_preflight --local
  assert_status 3
  assert_contains "$output" "model MacBookPro13,2 (a T1 Mac"
  assert_contains "$output" "warning: untested model"
}

@test "preflight --local: sees the stub toolchain and its T1 marker" {
  pf_load
  run cmd_preflight --local
  assert_status 3
  assert_contains "$output" "ok  bin/idevicerestore runs"
  assert_contains "$output" "ok  sbin/usbmuxd runs"
  assert_contains "$output" "idevicerestore carries the T1 patches"
}

@test "preflight --local: the T1 marker is found in a real-size binary under pipefail (no SIGPIPE)" {
  pf_load
  # marker first, then ~3 MB of printable padding: `strings | grep -q` exits on the marker while
  # strings is still writing, and under pipefail (bin/t1-revive sets it) the pipeline returned 141.
  { printf '#!/usr/bin/env bash\n# T1: EmbeddedOS restore options applied\nexit 0\n'
    head -c 3000000 /dev/zero | tr '\0' 'A' | fold -w 200 | sed 's/^/# /'; } >"$T1R_PREFIX/bin/idevicerestore"
  set -o pipefail
  run cmd_preflight --local
  set +o pipefail
  assert_contains "$output" "idevicerestore carries the T1 patches"
}

@test "preflight --local: an empty prefix is reported as missing binaries" {
  rm -rf "${T1R_PREFIX:?}/bin" "${T1R_PREFIX:?}/sbin"
  pf_load
  run cmd_preflight --local
  assert_status 3
  assert_contains "$output" "NO  bin/idevicerestore missing"
  assert_contains "$output" "NO  sbin/usbmuxd missing"
}

@test "preflight --local: an uncached firmware bundle is a NO line with --local" {
  pf_load
  run cmd_preflight --local
  assert_status 3
  assert_contains "$output" "firmware bundle not in the cache and --local given"
}

# --- the refusals and the other exit codes --------------------------------------------------
@test "preflight: an unsupported model exits 4 and stops at the model check" {
  t1r_use_dmi other; pf_load
  run cmd_preflight --local
  assert_status 4
  assert_contains "$output" "is not a T1 MacBook Pro; refusing"
  assert_contains "$output" "This machine is not a T1 MacBook Pro"
  # nothing after the model section may run
  refute_contains "$output" "restore toolchain"
  refute_contains "$output" "EFI system partition"
  assert_contains "$(t1r_diag_lines)" "step=preflight result=refused model_status=unsupported"
}

@test "preflight: exits 7 when the running kernel is not the installed one" {
  pf_load
  distro_kernel_matches() { return 1; }
  run cmd_preflight --local
  assert_status 7
  assert_contains "$output" "reboot, then run this again"
  assert_contains "$output" "Reboot, then run 't1-revive preflight' again."
  assert_contains "$(t1r_diag_lines)" "step=preflight result=reboot"
}

@test "preflight: an unknown flag exits 2 and --help exits 0" {
  pf_load
  run cmd_preflight --frobnicate
  assert_status 2
  assert_contains "$output" "unknown flag"
  run cmd_preflight --help
  assert_status 0
  assert_contains "$output" "usage: t1-revive preflight"
}

# --- --install ------------------------------------------------------------------------------
@test "preflight --local --install: the flag is accepted and installs nothing without root" {
  [[ ${EUID:-$(id -u)} -ne 0 ]] || skip "this test describes what a normal user gets"
  pf_load
  run cmd_preflight --local --install
  # accepted: not a usage error, and the run reaches the summary
  [[ $status -eq 3 || $status -eq 7 ]] || { echo "unexpected exit $status" >&2; return 1; }
  printf '%s\n' "$output" | grep -qE '^[0-9]+ ok, [0-9]+ problems$' || {
    echo "no summary line" >&2; return 1; }
  assert_contains "$output" "not running as root"
  assert_eq "" "$(cat "$T1R_TEST_INSTALLS")" "--install must not install anything without root"
}

@test "preflight: non-Arch systems say so instead of guessing" {
  t1r_use_osrelease other; pf_load
  run cmd_preflight --local
  assert_status 3
  assert_contains "$output" "package checks are implemented for Arch-based systems only"
  assert_contains "$output" "packages and kernel (nonesuch)"
}

@test "sourcing lib/cmd-preflight.sh has no side effects" {
  run bash -c '. "$T1R_ROOT/lib/common.sh"; . "$T1R_ROOT/lib/discover.sh"
               . "$T1R_ROOT/lib/distro.sh"; . "$T1R_ROOT/lib/cmd-preflight.sh"; echo sourced-ok'
  assert_status 0
  assert_eq "sourced-ok" "$output"
}

# --- the headers package of the running kernel (issue #9) -----------------------------------
# On Omarchy the booted kernel is linux-omarchy and its headers are in linux-omarchy-headers,
# while a stock, unbooted `linux` is usually installed as well. Asking for the stock
# `linux-headers` produced a NO and exit 3 on a machine whose headers were present and whose
# DKMS builds were fine.
pf_omarchy_kernel() {
  t1r_stub_pacman
  local p
  for p in libzip libusb curl openssl readline dkms acpi_call-dkms; do
    t1r_pacman_installed "$p" 1.0-1
  done
  t1r_pacman_installed linux 7.2.3.arch1-3
  t1r_pacman_installed linux-omarchy 7.2.5-3
  t1r_pacman_installed linux-omarchy-headers 7.2.5-3
  t1r_pacman_owns "$(t1r_kernel_dir)/vmlinuz" linux-omarchy
  t1r_pacman_owns "$(t1r_kernel_dir)/build" linux-omarchy-headers
}

@test "preflight: the booted kernel's headers count, the stock linux-headers are not demanded" {
  pf_omarchy_kernel
  pf_load
  run cmd_preflight --local
  refute_contains "$output" 'missing packages'
  assert_contains "$output" 'linux-omarchy-headers'
  printf '%s\n' "$output" | grep -q '^  ok  .*kernel headers for' || {
    echo "the headers check did not pass" >&2; return 1; }
}

@test "preflight: headers that really are missing are still a NO, named for this kernel" {
  t1r_stub_pacman
  local p
  for p in libzip libusb curl openssl readline dkms acpi_call-dkms; do
    t1r_pacman_installed "$p" 1.0-1
  done
  t1r_pacman_installed linux-omarchy 7.2.5-3
  t1r_pacman_owns "$(t1r_kernel_dir)/vmlinuz" linux-omarchy
  pf_load
  run cmd_preflight --local
  assert_status 3
  assert_contains "$output" 'missing packages: linux-omarchy-headers'
  printf '%s\n' "$output" | grep -q '^  NO  no kernel headers for' || {
    echo "the headers check should have failed" >&2; return 1; }
}

# --- an older Touch Bar stack blocks the run (issue #10) -------------------------------------
# On a 13,2 the legacy apple-ib-drv stack pinned the T1 to USB configuration 1 and the boot
# step reached 8600 and then wedged, twice, with code 5. Preflight has to say so before the
# run rather than after it.
@test "preflight: an older Touch Bar stack is a NO that names what was found" {
  pf_load
  legacy_t1_stack() {
    printf 'module apple_ibridge
dkms apple-ib-drv
udev /etc/udev/rules.d/99-ibridge.rules
'
  }
  run cmd_preflight --local
  assert_status 3
  printf '%s
' "$output" | grep -q '^  NO  an older Touch Bar stack' || {
    echo "no NO line for the legacy stack" >&2; return 1; }
  assert_contains "$output" 'module apple_ibridge'
  assert_contains "$output" 'dkms apple-ib-drv'
  assert_contains "$output" '99-ibridge.rules'
  assert_contains "$output" 'a blacklist alone does not help'
}

@test "preflight: a packaged rule pinning the T1 gets the override advice" {
  pf_load
  legacy_t1_stack() { printf 'udev-pkg /usr/lib/udev/rules.d/39-usbmuxd.rules\n'; }
  run cmd_preflight --local
  assert_status 3
  assert_contains "$output" 'udev-pkg /usr/lib/udev/rules.d/39-usbmuxd.rules'
  assert_contains "$output" 'override it with a same-named copy in /etc/udev/rules.d'
}

@test "preflight: a clean machine gets an ok line for the legacy stack check" {
  pf_load
  run cmd_preflight --local
  printf '%s
' "$output" | grep -q '^  ok  no older Touch Bar stack' || {
    echo "no ok line for the legacy stack check" >&2; return 1; }
}
