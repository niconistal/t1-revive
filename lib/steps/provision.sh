# lib/steps/provision.sh - step_provision: the EmbeddedOS restore that makes the
# T1 obtain its own device-specific FDR identity data from Apple's FDR service.
# ported from pass-a.sh.
#
# THIS TALKS TO THE T1 AND IS NOT REVERSIBLE. It does not touch the ESP, the
# Linux filesystem or macOS, and it does not call FRST (that is the next step).
# Everything identity-bearing is written 0600 under $T1R_STATE/private and is
# never printed.
# shellcheck shell=bash

step_provision() {
  local priv fw rc boot_args
  prefix_env
  fw=$(firmware_dir) || exit "$?"
  boot_args='rd=md0 -restore IOUSBDeviceController-configuration=standardMuxOnly'

  say "provision: preflight checks"
  # 1. The T1 must be in recovery. If it is already 8600 we must not touch it.
  t1_forbid booted 5 "a device is already at 05ac:8600 - the T1 is alive, do NOT run provision"
  t1_require recovery 5 "no 05ac:1281 device found"
  note "T1 in recovery"
  # 2. Binaries must be the patched ones.
  [ -x "$T1R_MUX" ] || die 3 "patched usbmuxd not built at $T1R_MUX"
  check_idevicerestore "T1: EmbeddedOS restore options applied"
  note "patched binaries OK"
  # 3. Firmware bundle.
  bundle_ok "$fw"
  note "firmware bundle OK"
  # 4. No system usbmuxd competing.
  no_system_usbmuxd 3
  note "no competing usbmuxd"

  priv=$(priv_dir) || exit 1
  # A new store invalidates everything personalize made from the old one: set all of it aside,
  # so neither the gate below nor a later step can pick up a file an earlier attempt left.
  set_aside_artifacts provision FDRData FDRData.replayed combined.preflight.memboot preflight.apticket

  say "provision: starting private usbmuxd"
  start_usbmuxd "$priv"

  say "provision: EmbeddedOS restore with FDR output armed"
  note "(this takes a few minutes; do not unplug or sleep the machine)"
  install -m 600 /dev/null "$priv/fdr-create.private.log"
  install -m 600 /dev/null "$priv/fdr-create-runner.private.log"

  dry env \
    -u IDEVICERESTORE_T1_FDR_INPUT \
    -u IDEVICERESTORE_T1_PREFLIGHT_MEMBOOT_SAVE \
    -u IDEVICERESTORE_T1_PREFLIGHT_TICKET_SAVE \
    -u IDEVICERESTORE_T1_PHASE14 \
    -u IDEVICERESTORE_T1_APTICKET_FILE \
    -u IDEVICERESTORE_MEMBOOT_FILE \
    -u IDEVICERESTORE_MEMBOOT_EXACT \
    -u IDEVICERESTORE_MEMBOOT_SAVE \
    -u IDEVICERESTORE_MEMBOOT_2GMI \
    -u IDEVICERESTORE_OSRAMDISK \
    -u IDEVICERESTORE_OSRAMDISK_SEPARATE \
    LD_LIBRARY_PATH="$T1R_LIBS" \
    IDEVICERESTORE_T1_EMBEDDEDOS=1 \
    IDEVICERESTORE_T1_FDR_OUTPUT="$priv/FDRData" \
    IDEVICERESTORE_RESTORE_BOOT_ARGS="$boot_args" \
    "$T1R_IDR" -y --variant 'Customer Boot' \
    --logfile="$priv/fdr-create.private.log" \
    "$fw" \
    2>&1 | tee "$priv/fdr-create-runner.private.log" \
         | redact_restore
  rc=${PIPESTATUS[0]}
  chmod 600 "$priv"/*.log 2>/dev/null

  say "provision: result"
  restore_report "$priv/fdr-create-runner.private.log" "$rc"
  if [ -s "$priv/FDRData" ]; then
    note "FDRData: $(stat -c '%s bytes mode %a' "$priv/FDRData")"
    if LD_LIBRARY_PATH="$T1R_LIBS" "$T1R_PLISTUTIL" -i "$priv/FDRData" -o /dev/null 2>/dev/null; then
      note "FDRData parses as a plist: yes"
    else
      note "FDRData parses as a plist: NO (may be raw data - that is still usable)"
    fi
    chmod 600 "$priv/FDRData"
  else
    note "FDRData: MISSING OR EMPTY"
  fi

  say "provision: T1 USB state now"
  usb_report

  note "stopping private usbmuxd"
  stop_usbmuxd
  note "provision finished. NOTHING has been written to the ESP."
  sleep 0.5
  # Gate as the proven run did: the store exists. idevicerestore's exit status is recorded in the
  # log and diag; it is fatal only with --strict (the original always exited 0 here).
  if is_dry; then note "(dry) artefact gate skipped (no restore ran)"; return 0; fi
  diag step=provision restore_rc="$rc"
  [ -s "$priv/FDRData" ] || { warn "provision finished but no FDRData"; return 1; }
  if [ "$rc" != 0 ]; then
    if [ "${T1R_STRICT:-0}" = 1 ]; then warn "idevicerestore exited $rc (--strict: treating as failure)"; return 1; fi
    warn "idevicerestore exited $rc but FDRData was written; continuing as the proven run did (use --strict to stop here)"
  fi
  return 0
}
