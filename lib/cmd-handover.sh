# lib/cmd-handover.sh - cmd_handover: hand a T1 that is already booted
# (05ac:8600) to t1bridge without a restart. Port of one-shot.sh step 5 and
# the no-reboot handover proven 2026-09-07 (re-enumerating the USB
# device makes t1bridge's configuration selector pick configuration 2; udev
# then starts the t1bridge stack on its own).
#
# Without t1bridge's selector module there is nothing to hand the T1 to: the
# command then says what to install and leaves the T1 running as it is.
# shellcheck shell=bash

# The dispatcher sources only lib/cmd-<sub>.sh; pull in the shared step code.
_t1r_lib=${T1R_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}/lib
# shellcheck source=steps/common-steps.sh
declare -F run_step >/dev/null 2>&1 || . "$_t1r_lib/steps/common-steps.sh"

# handover_embeddedos_dir: where the staged EMBEDDEDOS set is mounted right now, for the
# import command handover prints. Looks only at what is already mounted (the ESP of a
# regenerate run, then /boot and /efi); mounts nothing. Empty when none is found.
handover_embeddedos_dir() {
  local d
  for d in ${ESP_MNT:+"$ESP_MNT"} /boot /efi /boot/efi; do
    [ -d "$d/EFI/APPLE/EMBEDDEDOS" ] && { printf '%s\n' "$d/EFI/APPLE/EMBEDDEDOS"; return 0; }
  done
  return 0
}

# handover_touchid_advice STATUS [EMBEDDEDOS_DIR]: what to tell the user about Touch ID, from
# the `t1bridge status` text. A machine that already had Touch ID keeps it: the keybag is
# restored with the device. Any other machine needs t1bridge's machine data and an
# enrolment, and on freshly regenerated data the automatic import can finish with the
# machine data empty, after which every enrolment fails at once (t1bridge#29). The import
# by hand against the staged set is what fixed it there, so print that exact command.
handover_touchid_advice() {
  local status=$1 dir=${2:-}
  case "$status" in
    *"keybag: ready"*)
      note "Touch ID: the existing enrolment stays valid (keybag ready)."
      return 0;;
  esac
  note "Touch ID needs t1bridge's machine data and an enrolment. On freshly regenerated data the"
  note "automatic import can leave the machine data empty and every enrolment then fails at once"
  note "(t1bridge#29). Import the staged set by hand first, then enroll:"
  note "   sudo t1bridge machine-data import --from ${dir:-<ESP mount>/EFI/APPLE/EMBEDDEDOS}"
  note "   fprintd-enroll -f right-index-finger"
  note "A first enrolment that fails once is the keybag still bootstrapping; retry once (docs/omarchy.md, section 3)."
  return 0
}

cmd_handover() {
  local dev cfg m status sock=/run/t1bridge/touchbar.sock
  status=
  [ $# -eq 0 ] || die 2 "usage: t1-revive handover"
  require_root
  open_log_once handover
  lock_once

  say "handover: giving the booted T1 to t1bridge"
  t1_require booted 5 "the T1 is not at 05ac:8600; handover needs a booted T1 (power cycle, then: t1-revive handover)"
  dev=$(t1_sysfs)
  if [ -z "$dev" ]; then
    is_dry && dev="${T1R_SYSFS:-/sys}/bus/usb/devices/T1"
    [ -n "$dev" ] || die 5 "cannot find the T1's sysfs node"
  fi

  if ! modinfo -n t1_cfgsel >/dev/null 2>&1 && ! command -v t1bridge >/dev/null 2>&1; then
    note "t1bridge is not installed on this machine, so nothing takes the T1 yet."
    note "The T1 keeps running the regenerated image; once the ESP is staged it boots from it on its own."
    note "Next: install t1bridge (https://github.com/standardagents/t1bridge; on Omarchy see docs/omarchy.md),"
    note "then run: t1-revive handover   (or simply power cycle once)."
    diag step=handover result=skipped reason=no-t1bridge
    return 0
  fi

  note "t1bridge is installed: re-enumerating the T1 so its configuration selector takes it (no reboot)"
  [ "${T1R_DEMO:-0}" = 1 ] && show "  Handing the Touch Bar to its driver"
  dry_q modprobe t1_cfgsel || true
  confirm_each "re-enumerate the T1 (${dev##*/})"
  dry_write "$dev/authorized" '%s\n' 0; dry_sleep 2
  for m in apple_touchbar apple_ibridge; do
    if dry_q modprobe -r "$m"; then note "unloaded firmware-bar driver $m"; fi
  done
  dry_write "$dev/authorized" '%s\n' 1; dry_sleep 4

  if is_dry; then
    note "(dry) read bConfigurationValue (2 = t1bridge owns it)"
  else
    cfg=$(t1_config)
    if [ "$cfg" != 2 ]; then                      # give udev/t1_cfgsel a few more seconds
      for _ in $(seq 1 12); do sleep 0.5; cfg=$(t1_config); [ "$cfg" = 2 ] && break; done
    fi
    note "T1 configuration now: ${cfg:-unset} (2 = t1bridge owns it)"
    [ "$cfg" = 2 ] || warn "t1bridge's selector did not take the T1 (configuration ${cfg:-unset}); a full power cycle will"
    diag step=handover result=enumerated config="${cfg:-none}"
  fi

  if command -v t1bridge >/dev/null 2>&1; then
    if ! is_dry; then
      for _ in $(seq 1 30); do [ -S "$sock" ] && break; sleep 0.5; done
      if [ -S "$sock" ]; then note "t1bridge hardware socket is up"; else warn "t1bridge hardware socket did not appear within 15 s"; fi
      sleep 3
      status=$(t1bridge status 2>/dev/null || true)
      [ -n "$status" ] && printf '%s\n' "$status" | sed 's/^/   /'
    else
      note "(dry) wait up to 15 s for $sock, then: t1bridge status"
    fi
    note "If the Touch Bar is not drawn by t1bridge within ~10 s: full power cycle (the ESP is staged, it comes back)."
    handover_touchid_advice "$status" "$(handover_embeddedos_dir)"
  else
    note "t1bridge's selector module is present but the t1bridge CLI is not; install the t1bridge packages, then check: t1bridge status"
  fi
  return 0
}
