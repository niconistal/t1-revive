# lib/cmd-stage.sh - cmd_stage: put the proven memboot image, FDRData and
# version.plist on the ESP under EFI/APPLE/EMBEDDEDOS. Port of stage-esp.sh.
#
#   t1-revive stage            write, verify with cmp
#   t1-revive stage --dry-run  all checks, no writes
#   t1-revive stage --force    even without the boot done marker (warns)
#
# Run only after the boot step reported 05ac:8600 stable. Two phases: all three files are
# first written under temporary names on the same filesystem and synced, and only then
# renamed into place, combined.memboot last. An interruption while writing leaves the old
# set untouched; one between the renames leaves .<name>.new files, which the next stage
# (and status) report, and rerunning stage completes the set from private/. FAT has no
# atomic multi-file swap, so this narrows the mixed-set window to three renames rather
# than closing it. Everything is read back with cmp. Nothing else on the ESP is touched.
# shellcheck shell=bash

# The dispatcher sources only lib/cmd-<sub>.sh; pull in the shared step code.
_t1r_lib=${T1R_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}/lib
# shellcheck source=steps/common-steps.sh
declare -F run_step >/dev/null 2>&1 || . "$_t1r_lib/steps/common-steps.sh"

cmd_stage() {
  local dry=0 force=0 a fw priv image fdr vers esp_mnt esp src avail need ts f h hid ok
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1;;
      --force) force=1;;
      *) die 2 "usage: t1-revive stage [--dry-run] [--force]";;
    esac
  done
  is_dry && dry=1
  # A dry run must not mount anything either: make every helper see it.
  [ "$dry" = 1 ] && { T1R_DRY_RUN=1; export T1R_DRY_RUN; }

  require_root
  open_log_once stage
  lock_once
  prefix_env
  fw=$(firmware_dir) || exit "$?"
  priv="${T1R_STATE:?}/private"
  image="$priv/combined.preflight.memboot"
  fdr="$priv/FDRData"
  vers="$(dirname "$fw")/version.plist"

  [ "$dry" = 1 ] && note "*** DRY RUN: nothing will be written ***"

  say "stage: preflight checks"
  # The boot marker must be newer than the image it vouches for; a marker from an earlier run
  # says nothing about an image captured later.
  if step_done boot && [ -s "$image" ] && [ ! "$(step_marker_dir)/boot.done" -nt "$image" ]; then
    warn "the boot marker is older than the current image; treating the boot step as not done"
    rm -f "$(step_marker_dir)/boot.done"
  fi
  if ! step_done boot; then
    if [ "$force" = 1 ]; then
      warn "the boot step has not completed on this machine; --force given, staging anyway"
    elif is_dry; then
      note "(dry) no boot marker: a real run would refuse here"
    else
      die 4 "the boot step has not completed on this machine (no done marker). Run: t1-revive regenerate --from boot, or add --force if you know the T1 is running this image"
    fi
  fi

  # The ESP must really be the ESP, mounted rw.
  esp_resolve_or_die; esp_mnt=$ESP_MNT
  esp="$esp_mnt/EFI/APPLE/EMBEDDEDOS"
  if src=$(findmnt -no SOURCE,FSTYPE,OPTIONS "$esp_mnt" 2>/dev/null); then
    case "$src" in *vfat*rw*) ;; *) die 4 "$esp_mnt is not a rw vfat mount: $src";; esac
    note "ESP: $src"
  else
    is_dry || die 4 "$esp_mnt is not a mountpoint"
    note "(dry) ESP mount check skipped ($esp_mnt)"
  fi
  avail=$(df --output=avail -B1 "$esp_mnt" 2>/dev/null | tail -1); avail=${avail:-0}
  note "free: $((avail/1024/1024)) MiB"

  # The T1 must be alive right now - staging is only for a running image.
  t1_require booted 5 "no 05ac:8600 present - stage only while the proven image is running"
  hid=0
  for h in "${T1R_SYSFS:-/sys}"/bus/hid/devices/*05AC:8600* "${T1R_SYSFS:-/sys}"/bus/hid/devices/*1D6B:0301*; do [ -e "$h" ] && hid=1; done
  if [ "$hid" = 1 ]; then note "T1 alive at 8600 with HID: yes"
  elif is_dry; then note "(dry) HID check skipped"
  else die 5 "iBridge is at 8600 but exposes no HID devices - that is the degraded restore personality, not a booted EmbeddedOS"; fi

  expect_file "$image" 4 "missing preflight image (run the personalize step first)"
  expect_file "$fdr" 4 "missing FDRData (run the provision step first)"
  if [ ! -s "$vers" ]; then is_dry || die 6 "missing version.plist in the firmware bundle"; fi
  need=$(( $(stat -c %s "$image" 2>/dev/null || echo 0) + $(stat -c %s "$fdr" 2>/dev/null || echo 0) + $(stat -c %s "$vers" 2>/dev/null || echo 0) + 1048576 ))
  if [ "$avail" -lt "$need" ]; then is_dry || die 4 "not enough space on the ESP ($avail < $need)"; fi
  note "image:  $(file_size "$image") bytes"
  note "FDR:    $(file_size "$fdr") bytes"
  note "vers:   $(file_size "$vers") bytes"

  say "stage: existing EFI/APPLE/EMBEDDEDOS"
  if [ -d "$esp" ]; then
    # shellcheck disable=SC2012
    ls -la "$esp" 2>/dev/null | sed 's/^/   /'
    ts=$(date +%Y%m%d-%H%M%S)
    for f in combined.memboot FDRData version.plist; do
      if [ -f "$esp/$f" ]; then
        note "backing up $f -> private/esp-backup-$ts/$f"
        _stage_run "$dry" install -d -m 700 "$priv/esp-backup-$ts"
        _stage_run "$dry" install -m 600 "$esp/$f" "$priv/esp-backup-$ts/$f"
      fi
    done
  else
    note "(absent - will be created)"
    _stage_run "$dry" install -d "$esp"
  fi

  if [ -n "$(stage_leftovers "$esp")" ]; then
    warn "an earlier stage was interrupted (left: $(stage_leftovers "$esp")); this run replaces them and completes the set"
  fi

  say "stage: staging (write all three, then rename)"
  _stage_write "$dry" "$image" "$esp" combined.memboot
  _stage_write "$dry" "$fdr"   "$esp" FDRData
  _stage_write "$dry" "$vers"  "$esp" version.plist
  _stage_run "$dry" sync "$esp_mnt"
  _stage_rename "$dry" "$esp" FDRData
  _stage_rename "$dry" "$esp" version.plist
  _stage_rename "$dry" "$esp" combined.memboot
  _stage_run "$dry" sync "$esp_mnt"

  say "stage: verify"
  if [ "$dry" = 1 ]; then
    note "(dry) skipped"
    return 0
  fi
  ok=1
  if cmp -s "$image" "$esp/combined.memboot"; then note "combined.memboot verified"; else note "combined.memboot MISMATCH"; ok=0; fi
  if cmp -s "$fdr"   "$esp/FDRData";          then note "FDRData verified";          else note "FDRData MISMATCH"; ok=0; fi
  if cmp -s "$vers"  "$esp/version.plist";    then note "version.plist verified";    else note "version.plist MISMATCH"; ok=0; fi
  # shellcheck disable=SC2012
  ls -la "$esp" | sed 's/^/   /'
  if [ "$ok" = 1 ]; then
    note "STAGED. The T1 boots from the ESP on the next power-on."
    diag step=stage result=verified
    return 0
  fi
  die 5 "ESP verification failed - do not reboot until fixed (rerun: t1-revive stage --force)"
}

# _stage_run DRY CMD...: stage-esp.sh's run(): print in a dry run, else run.
_stage_run() {
  local d=$1; shift
  if [ "$d" = 1 ]; then note "(dry) $*"; else "$@"; fi
}

# _stage_write DRY SRC ESPDIR NAME: write NAME under its temporary name and sync it.
_stage_write() {
  local d=$1 s=$2 esp=$3 n=$4
  note "$n"
  _stage_run "$d" install -m 644 "$s" "$esp/.$n.new"
  _stage_run "$d" sync -f "$esp/.$n.new"
}

# _stage_rename DRY ESPDIR NAME: move the synced temporary file into place.
_stage_rename() {
  local d=$1 esp=$2 n=$3
  _stage_run "$d" mv -f "$esp/.$n.new" "$esp/$n"
}

# stage_leftovers ESPDIR: the temporary files an interrupted stage left, space-separated.
stage_leftovers() {
  local esp=${1:?stage_leftovers ESPDIR} n out=
  for n in combined.memboot FDRData version.plist; do
    [ -e "$esp/.$n.new" ] && out="$out${out:+ }.$n.new"
  done
  printf '%s' "$out"
}
