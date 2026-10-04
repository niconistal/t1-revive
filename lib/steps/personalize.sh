# lib/steps/personalize.sh - step_personalize: replay the provisioned FDR store
# and capture the boot image personalised for this chip plus its AP ticket.
# ported from pass-b.sh.
#
# THIS TALKS TO THE T1 AND IS NOT REVERSIBLE. Same EmbeddedOS restore as
# provision, with the FDR store replayed as input and the preflight image +
# ticket saved; the boot step replays exactly that pair. No ESP or
# Linux-install writes; no FRST. Identity-bearing data stays 0600 under
# $T1R_STATE/private.
# shellcheck shell=bash

step_personalize() {
  local priv fw rc boot_args f ok replay=unknown
  prefix_env
  fw=$(firmware_dir) || exit "$?"
  boot_args='rd=md0 -restore IOUSBDeviceController-configuration=standardMuxOnly'
  priv="${T1R_STATE:?}/private"

  say "personalize: preflight checks"
  # 1. The T1 must be in recovery. If it is already 8600 we must not touch it.
  t1_forbid booted 5 "a device is already at 05ac:8600 - the T1 is alive, do NOT run personalize"
  t1_require recovery 5 "no 05ac:1281 device found"
  note "T1 in recovery"
  # 2. Binaries must be the patched ones.
  [ -x "$T1R_MUX" ] || die 3 "patched usbmuxd not built at $T1R_MUX"
  check_idevicerestore "T1: EmbeddedOS restore options applied"
  note "patched binaries OK"
  # 2b. The provisioned FDR store must exist - it is the whole point of this step.
  expect_file "$priv/FDRData" 4 "no FDRData from the provision step (run: t1-revive regenerate --from provision)"
  if ! is_dry; then
    LD_LIBRARY_PATH="$T1R_LIBS" "$T1R_PLISTUTIL" -i "$priv/FDRData" -o /dev/null 2>/dev/null \
      || die 4 "the provisioned FDRData does not parse as a plist"
  fi
  note "provisioned FDRData present ($(file_size "$priv/FDRData") bytes)"
  # 3. Firmware bundle.
  bundle_ok "$fw"
  note "firmware bundle OK"
  # 4. No system usbmuxd competing.
  no_system_usbmuxd 3
  note "no competing usbmuxd"

  priv=$(priv_dir) || exit 1
  # Only this attempt's image, ticket and replayed store may pass the gate below.
  set_aside_artifacts personalize FDRData.replayed combined.preflight.memboot preflight.apticket

  say "personalize: starting private usbmuxd"
  start_usbmuxd "$priv"

  say "personalize: EmbeddedOS restore with FDR INPUT replayed + preflight capture"
  note "(this takes a few minutes; do not unplug or sleep the machine)"
  install -m 600 /dev/null "$priv/phase11.private.log"
  install -m 600 /dev/null "$priv/phase11-runner.private.log"

  dry env \
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
    IDEVICERESTORE_T1_FDR_INPUT="$priv/FDRData" \
    IDEVICERESTORE_T1_FDR_OUTPUT="$priv/FDRData.replayed" \
    IDEVICERESTORE_T1_PREFLIGHT_MEMBOOT_SAVE="$priv/combined.preflight.memboot" \
    IDEVICERESTORE_T1_PREFLIGHT_TICKET_SAVE="$priv/preflight.apticket" \
    IDEVICERESTORE_RESTORE_BOOT_ARGS="$boot_args" \
    "$T1R_IDR" -y --variant 'Customer Boot' \
    --logfile="$priv/phase11.private.log" \
    "$fw" \
    2>&1 | tee "$priv/phase11-runner.private.log" \
         | redact_restore
  rc=${PIPESTATUS[0]}
  chmod 600 "$priv"/*.log 2>/dev/null

  say "personalize: result"
  restore_report "$priv/phase11-runner.private.log" "$rc"
  ok=1
  for f in combined.preflight.memboot preflight.apticket FDRData.replayed; do
    if [ -s "$priv/$f" ]; then
      chmod 600 "$priv/$f"
      note "$f: $(stat -c '%s bytes mode %a' "$priv/$f")"
    else
      note "$f: MISSING OR EMPTY"; ok=0
    fi
  done
  if [ -s "$priv/FDRData.replayed" ]; then
    if cmp -s "$priv/FDRData" "$priv/FDRData.replayed"; then
      replay=yes
      note "FDR replay matches the provisioned store byte-for-byte: yes"
    elif fdr_replay_matches "$priv/FDRData" "$priv/FDRData.replayed"; then
      replay=yes
      note "FDR replay matches the provisioned store: yes (same plist, different bytes)"
    else
      replay=no; ok=0
      note "FDR replay matches the provisioned store: NO (sizes: $(file_size "$priv/FDRData") vs $(file_size "$priv/FDRData.replayed"))"
    fi
  fi
  if [ "$ok" = 1 ] && [ "$rc" = 0 ]; then
    note "PERSONALIZE: all artefacts captured."
  else
    note "PERSONALIZE: incomplete - do NOT boot the T1 with these artefacts."
  fi

  say "personalize: T1 USB state now"
  usb_report

  note "stopping private usbmuxd"
  stop_usbmuxd
  note "personalize finished. NOTHING has been written to the ESP."
  sleep 0.5
  # Gate as the proven run did: image and ticket exist, and now also a replayed store that is
  # the provisioned one (always fatal). Exit status and a missing replayed store are fatal only
  # with --strict.
  if is_dry; then note "(dry) artefact gate skipped (no restore ran)"; return 0; fi
  diag step=personalize restore_rc="$rc" artefacts_ok="$ok" replay="$replay"
  # A replayed store that is not the provisioned one means the image and ticket were made
  # against different identity data than the FDRData that would be staged next to them.
  # Never continue from that, with or without --strict; set the pair aside so neither boot
  # nor stage can use it.
  if [ "$replay" = no ]; then
    set_aside_artifacts personalize-replay-mismatch combined.preflight.memboot preflight.apticket FDRData.replayed
    warn "the replayed FDR store differs from the provisioned one; do NOT boot or stage. Start again: t1-revive regenerate --from provision"
    return 1
  fi
  if [ ! -s "$priv/combined.preflight.memboot" ] || [ ! -s "$priv/preflight.apticket" ]; then
    warn "personalize finished but image/ticket missing"; return 1
  fi
  if [ "$rc" != 0 ] || [ "$ok" != 1 ]; then
    if [ "${T1R_STRICT:-0}" = 1 ]; then warn "personalize incomplete (rc=$rc, artefacts=$ok); --strict: stopping"; return 1; fi
    warn "personalize: idevicerestore exited $rc, artefacts complete=$ok; image and ticket are present so continuing as the proven run did (use --strict to stop here)"
  fi
  return 0
}
