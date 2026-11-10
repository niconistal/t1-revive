#!/usr/bin/env bash
# lib/discover.sh - ESP, DMI model + allowlist, FRST ACPI path.
#
# Pure with respect to T1R_* variables: T1R_DMI, T1R_LSBLK_JSON, T1R_ACPI_TABLES, T1R_STATE.
# Nothing runs at source time. Requires lib/common.sh (note/warn/die/run_cmd).
#
# shellcheck shell=bash

T1R_ESP_PARTTYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
export T1R_ESP_PARTTYPE
# T1R_ESP_DEV: optional operator override (t1-revive.conf) for a machine with two ESPs.
: "${T1R_ESP_DEV:=}"
export T1R_ESP_DEV

# ----- model ---------------------------------------------------------------------------
model_id() {
  local m=
  [[ -r "$T1R_DMI/product_name" ]] && read -r m <"$T1R_DMI/product_name" 2>/dev/null
  printf '%s\n' "${m:-unknown}"
}

# The allowlist, in two lists so a model moves from one to the other when a tester confirms it
# (the README table is the record). Every T1 Mac is on one of them; anything else is refused.
# Tested means: a regeneration on that model was reported, staged and survived a cold boot.
T1R_TESTED_MODELS="MacBookPro14,3 MacBookPro14,2 MacBookPro13,3 MacBookPro13,2"
T1R_UNTESTED_MODELS=""
export T1R_TESTED_MODELS T1R_UNTESTED_MODELS

model_status() {
  local m=${1:-}
  [[ -n "$m" ]] || { printf 'unsupported\n'; return; }
  case " $T1R_TESTED_MODELS " in *" $m "*) printf 'tested\n'; return;; esac
  case " $T1R_UNTESTED_MODELS " in *" $m "*) printf 'untested\n'; return;; esac
  printf 'unsupported\n'
}

# ----- leftovers of older Touch Bar stacks ----------------------------------------------
# The pre-t1bridge out-of-tree drivers (apple-ib-drv and its forks) bind the T1's HID
# interfaces and pin its USB configuration to 1. That fights every step of a regeneration:
# the boot step reaches 05ac:8600 and the post-watch USB walk then wedges (issue #10, where
# the chain died twice with code 5 before the stack was disabled). Blacklisting is not
# enough on its own - the reported machine had a unit that `insmod`s the module late, which
# is why an installed-but-unloaded DKMS build counts as a finding too.
T1R_LEGACY_MODULES="apple_ibridge apple_ib_tb apple_ib_als appletb"
# DKMS names its packages, not its modules: apple-ib-drv is the source package that builds
# apple_ibridge, apple_ib_tb and apple_ib_als, so the two lists do not overlap by spelling.
T1R_LEGACY_DKMS="apple-ib-drv apple-ibridge apple-touchbar appletb"
# Admin-provided rule directories: any T1-related rule that pins a configuration is flagged.
: "${T1R_UDEV_RULES_DIRS:=/etc/udev/rules.d /run/udev/rules.d}"
# Package-provided rule directories hold t1bridge's own rules, which must never be flagged, but
# also usbmuxd's 39-usbmuxd.rules, which pins 05ac:8600 to configuration 1 on add and undoes
# t1bridge's display configuration after a regeneration (standardagents/t1bridge#64,
# libimobiledevice/usbmuxd#291). Here only a single rule line that both names 8600 and sets
# bConfigurationValue counts, and a file is skipped when a same-named file in an admin
# directory overrides it, as udev does.
: "${T1R_PKG_UDEV_RULES_DIRS:=/usr/lib/udev/rules.d}"
export T1R_LEGACY_MODULES T1R_LEGACY_DKMS T1R_UDEV_RULES_DIRS T1R_PKG_UDEV_RULES_DIRS

# legacy_t1_stack: one line per leftover found, "KIND DETAIL"; returns 1 when the machine is
# clean. Reads only - nothing is unloaded, unlinked or masked.
#   module NAME   a legacy module is loaded right now
#   dkms NAME     a legacy DKMS package is built and installed, so something can insmod it
#                 again after a blacklist or a reboot - both are reported when both are true
#   udev PATH     an admin udev rule that pins the T1's USB configuration
# _udev_rules FILE: the file's rules, one per line - continuation lines joined, comments and
# blank lines dropped - so a check can ask what a single rule does.
_udev_rules() {
  awk '{ sub(/^[ \t]+/, "") }
       /^#/ && cont == "" { next }
       /\\$/ { cont = cont substr($0, 1, length($0) - 1) " "; next }
       { line = cont $0; cont = ""; if (line !~ /^[ \t]*$/) print line }
       END { if (cont != "") print cont }' "$1" 2>/dev/null
}

# _udev_pins_t1 FILE PATTERN: 0 when one rule in FILE matches PATTERN (what identifies the T1)
# and also sets bConfigurationValue.
_udev_pins_t1() {
  _udev_rules "$1" | grep -F 'bConfigurationValue' | grep -qiE "$2"
}

legacy_t1_stack() {
  local found=1 m d f mods dk
  mods=$(lsmod 2>/dev/null) || mods=''
  dk=$(dkms status 2>/dev/null) || dk=''
  for m in $T1R_LEGACY_MODULES; do
    if printf '%s\n' "$mods" | awk -v m="$m" '$1==m{f=1} END{exit !f}'; then
      printf 'module %s\n' "$m"; found=0
    fi
  done
  for m in $T1R_LEGACY_DKMS; do
    if printf '%s\n' "$dk" | awk -v m="$m" 'index($0, m "/")==1{f=1} END{exit !f}'; then
      printf 'dkms %s\n' "$m"; found=0
    fi
  done
  for d in $T1R_UDEV_RULES_DIRS; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      # a configuration pin is only interesting when that same rule is about the T1 (a whole-
      # file match flagged an override whose comment names 05ac:8600 next to iPhone pins)
      if _udev_pins_t1 "$f" '05ac|8600|ibridge|touch ?bar'; then
        printf 'udev %s\n' "$f"; found=0
      fi
    done < <(grep -rlsF 'bConfigurationValue' "$d" 2>/dev/null | sort)
  done
  local a overridden
  for d in $T1R_PKG_UDEV_RULES_DIRS; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      overridden=0
      for a in $T1R_UDEV_RULES_DIRS; do
        [[ -e "$a/$(basename -- "$f")" ]] && overridden=1
      done
      [[ "$overridden" = 1 ]] && continue
      _udev_pins_t1 "$f" '8600' || continue
      printf 'udev-pkg %s\n' "$f"; found=0
    done < <(grep -lsF '8600' "$d"/*.rules 2>/dev/null | sort)
  done
  return "$found"
}

# ----- ESP -----------------------------------------------------------------------------
# _esp_lsblk_json: the lsblk tree as JSON (from T1R_LSBLK_JSON when set).
_esp_lsblk_json() {
  if [[ -n "${T1R_LSBLK_JSON:-}" ]]; then
    [[ -r "$T1R_LSBLK_JSON" ]] || return 1
    cat "$T1R_LSBLK_JSON"
  else
    command -v lsblk >/dev/null 2>&1 || return 1
    lsblk -J -o NAME,PATH,PARTTYPE,MOUNTPOINT,FSTYPE,LABEL 2>/dev/null
  fi
}

# _esp_parse: JSON on stdin -> "PATH MOUNTPOINT" for every ESP partition (mountpoint "-" if none)
_esp_parse() {
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg t "$T1R_ESP_PARTTYPE" '
      [.. | objects | select(has("parttype")) | select(((.parttype // "") | ascii_downcase) == $t)]
      | .[] | "\(.path // ("/dev/" + .name)) \(.mountpoint // (.mountpoints // [null])[0] // "-")"' 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
want = sys.argv[1]
def walk(n):
    if isinstance(n, dict):
        if str(n.get("parttype") or "").lower() == want:
            mp = n.get("mountpoint") or (n.get("mountpoints") or [None])[0] or "-"
            print("%s %s" % (n.get("path") or "/dev/" + str(n.get("name")), mp))
        for v in n.values(): walk(v)
    elif isinstance(n, list):
        for v in n: walk(v)
walk(json.load(sys.stdin))' "$T1R_ESP_PARTTYPE" 2>/dev/null
  else
    return 1
  fi
}

# T1R_ESP_PROBE: how an ESP that is not mounted is looked at. "auto" (default) mounts it
# read-only on a private temporary directory, as root, when the device really is a block
# device; "0" never mounts anything (the answer stays "?"); "1" always tries (the bats suite,
# with a stub mount(8) on PATH). A dual-boot Mac keeps Apple's ESP unmounted while Linux
# runs, so without the probe the partition that matters most is the one the tool cannot see.
: "${T1R_ESP_PROBE:=auto}"
export T1R_ESP_PROBE

# esp_apple_facts MOUNTPOINT: "EFI_APPLE EMBEDDEDOS MEMBOOT FDRDATA VERSION", yes/no each,
# for a mounted ESP. Reads directory entries only; never the files.
esp_apple_facts() {
  local mp=${1:?esp_apple_facts MOUNTPOINT} eos a=no e=no m=no f=no v=no
  eos=$mp/EFI/APPLE/EMBEDDEDOS
  [[ -d "$mp/EFI/APPLE" ]] && a=yes
  [[ -d "$eos" ]] && e=yes
  [[ -e "$eos/combined.memboot" ]] && m=yes
  [[ -e "$eos/FDRData" ]] && f=yes
  [[ -e "$eos/version.plist" ]] && v=yes
  printf '%s %s %s %s %s\n' "$a" "$e" "$m" "$f" "$v"
}

# esp_with_ro_mount DEVICE CMD [ARG...]: mount an unmounted ESP read-only on a private
# temporary directory, run CMD with the mountpoint appended to ARGs, unmount. Nothing is ever
# written: the mount is ro,nosuid,nodev,noexec and the directory is removed afterwards.
# Returns 1 (and runs nothing) when probing is off (T1R_ESP_PROBE=0), when not root on a real
# block device, or when the mount fails. CMD's own status is returned otherwise.
esp_with_ro_mount() {
  local dev=${1:?esp_with_ro_mount DEVICE} mp rc
  shift
  [[ $# -ge 1 ]] || return 2
  case "$T1R_ESP_PROBE" in
    0) return 1;;
    1) ;;
    *) [[ "${EUID:-$(id -u)}" = 0 ]] || return 1
       [[ -b "$dev" ]] || return 1;;
  esac
  command -v mount >/dev/null 2>&1 || return 1
  mp=$(mktemp -d "${TMPDIR:-/tmp}/t1-revive-probe.XXXXXX" 2>/dev/null) || return 1
  if ! mount -t vfat -o ro,nosuid,nodev,noexec "$dev" "$mp" 2>/dev/null; then
    rmdir "$mp" 2>/dev/null
    return 1
  fi
  "$@" "$mp"; rc=$?
  # A read-only probe that will not unmount (a stray open file) is detached lazily; the
  # directory is removed only once nothing is mounted on it, so a failure never hides a
  # mounted ESP behind a warning that only spoke of the directory.
  if umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null; then
    rmdir "$mp" 2>/dev/null || true
  else
    warn "could not unmount the read-only probe of $dev; run: umount $mp && rmdir $mp"
  fi
  return "$rc"
}

# esp_probe DEVICE: esp_apple_facts for an ESP that is not mounted, through a read-only probe
# mount. Prints nothing and returns 1 when the partition cannot be looked at.
esp_probe() { esp_with_ro_mount "${1:?esp_probe DEVICE}" esp_apple_facts; }

# esp_candidates: "DEVICE MOUNTPOINT HAS_APPLE" per ESP. HAS_APPLE is yes/no when the
# partition is mounted (EFI/APPLE present under the mountpoint) or when a read-only probe
# could look at it (see T1R_ESP_PROBE), "?" otherwise. Never mounts anything read-write.
esp_candidates() {
  local dev mp has facts
  while read -r dev mp; do
    [[ -n "$dev" ]] || continue
    if [[ "$mp" = "-" ]] || [[ -z "$mp" ]]; then
      if facts=$(esp_probe "$dev" 2>/dev/null) && [[ -n "$facts" ]]; then has=${facts%% *}; else has='?'; fi
    elif [[ ! -r "$mp" ]] || [[ ! -x "$mp" ]]; then has='?'   # mounted, but not for this user
    elif [[ -d "$mp/EFI/APPLE" ]]; then has=yes
    else has=no; fi
    printf '%s %s %s\n' "$dev" "${mp:--}" "$has"
  done < <(_esp_lsblk_json | _esp_parse)
  return 0
}

# esp_select [--why]: the one ESP to use, as "DEVICE MOUNTPOINT" (with --why, one sentence
# saying how it was chosen instead). Preference, in order: the device pinned by T1R_ESP_DEV;
# the only ESP; the single ESP on a non-removable disk that holds EFI/APPLE (the Mac's own
# ESP, whatever Linux mounted where); only when no ESP is known to hold EFI/APPLE, the one
# mounted at /boot, /efi or /boot/efi (a wiped single-ESP install, or an installer
# environment). Returns 1 if none or ambiguous.
#
# The EFI/APPLE rule must come first: a Linux install next to macOS leaves Apple's ESP
# unmounted and mounts its own at /boot, and picking /boot there means backup finds nothing to
# save on a machine whose firmware is intact, while stage would write next to the wrong
# bootloader.
esp_select() {
  local -a lines=()
  local why=0 l n dev mp has pick='' apple=0 std=0 unknown=0
  [[ "${1:-}" = --why ]] && why=1
  mapfile -t lines < <(esp_candidates)
  if [[ -n "${T1R_ESP_DEV:-}" ]]; then
    for l in "${lines[@]}"; do
      read -r dev mp _ <<<"$l"
      if [[ "$dev" = "$T1R_ESP_DEV" ]]; then
        [[ "$why" = 1 ]] && { printf 'pinned by T1R_ESP_DEV in t1-revive.conf\n'; return 0; }
        printf '%s %s\n' "$dev" "$mp"; return 0
      fi
    done
    warn "T1R_ESP_DEV=$T1R_ESP_DEV is not an EFI system partition on this machine; ignoring it"
  fi
  n=${#lines[@]}
  [[ "$n" -gt 0 ]] || return 1
  if [[ "$n" = 1 ]]; then
    read -r dev mp _ <<<"${lines[0]}"
    [[ "$why" = 1 ]] && { printf 'the only EFI system partition\n'; return 0; }
    printf '%s %s\n' "$dev" "$mp"; return 0
  fi
  for l in "${lines[@]}"; do
    read -r dev mp has <<<"$l"
    if [[ "$has" = yes ]] && ! esp_removable "$dev"; then apple=$((apple + 1)); pick="$dev $mp"; fi
  done
  if [[ "$apple" = 1 ]]; then
    [[ "$why" = 1 ]] && { printf 'the only EFI system partition on an internal disk that holds EFI/APPLE\n'; return 0; }
    printf '%s\n' "$pick"; return 0
  fi
  [[ "$apple" -gt 1 ]] && return 1
  pick=
  for l in "${lines[@]}"; do
    read -r dev mp has <<<"$l"
    [[ "$has" = '?' ]] && unknown=$((unknown + 1))
    case "$mp" in /boot|/efi|/boot/efi) std=$((std + 1)); pick="$dev $mp";; *) ;; esac
  done
  if [[ "$std" = 1 ]]; then
    if [[ "$why" = 1 ]]; then
      # The /boot rule only applies when no ESP is known to hold EFI/APPLE. An ESP nobody
      # could look inside (unmounted, and no root to probe it) may well be Apple's, so the
      # choice is provisional until every candidate has been looked at.
      if [[ "$unknown" -gt 0 ]]; then
        printf 'mounted at %s; provisional: %d EFI system partition(s) could not be looked inside' "${pick#* }" "$unknown"
        if [[ "${EUID:-$(id -u)}" = 0 ]]; then printf '\n'; else printf ', run as root to be sure\n'; fi
      else
        printf 'mounted at %s, and no EFI system partition is known to hold EFI/APPLE\n' "${pick#* }"
      fi
      return 0
    fi
    printf '%s\n' "$pick"; return 0
  fi
  return 1
}

# esp_removable DEVICE: true when the disk behind the partition is flagged removable in sysfs
# (USB sticks); unknown counts as not removable.
esp_removable() {
  local d=${1#/dev/} disk
  case "$d" in nvme*) disk=${d%p[0-9]*};; mmcblk*) disk=${d%p[0-9]*};; *) disk=${d%%[0-9]*};; esac
  [[ "$(cat "${T1R_SYSFS:-/sys}/block/$disk/removable" 2>/dev/null)" = 1 ]]
}

# esp_mount DEVICE [ro]: prints the mountpoint, mounting under $T1R_STATE/esp when needed.
# With "ro" a mount the tool makes itself is read-only (ro,nosuid,nodev,noexec): backup and
# preflight only ever read, so they cannot write to the partition they exist to protect. An
# ESP that is already mounted is used as it is, whatever the mode.
esp_mount() {
  local dev=${1:?esp_mount DEVICE} mode=${2:-rw} mp='' l d m
  while read -r d m _; do [[ "$d" = "$dev" ]] && mp=$m; done < <(esp_candidates)
  if { [[ -z "$mp" ]] || [[ "$mp" = "-" ]]; } && command -v findmnt >/dev/null 2>&1; then
    mp=$(findmnt -rno TARGET "$dev" 2>/dev/null | head -1)
  fi
  if [[ -n "$mp" ]] && [[ "$mp" != "-" ]]; then printf '%s\n' "$mp"; return 0; fi
  mp=$T1R_STATE/esp
  if [[ "$T1R_DRY_RUN" = 1 ]]; then note "(dry-run) mount $dev $mp"; printf '%s\n' "$mp"; return 0; fi
  install -d -m 0700 "$mp" || return 1
  if [[ "$mode" = ro ]]; then mount -t vfat -o ro,nosuid,nodev,noexec "$dev" "$mp" || return 1
  else mount -t vfat "$dev" "$mp" || return 1; fi
  l=$(findmnt -rno FSTYPE "$mp" 2>/dev/null); [[ "$l" = vfat ]] || { umount "$mp" 2>/dev/null; return 1; }
  T1R_ESP_MOUNTED=$mp; export T1R_ESP_MOUNTED   # esp_release unmounts it at exit
  printf '%s\n' "$mp"
}

# esp_release: unmount an ESP that esp_mount mounted itself (called from log_close at exit).
# esp_mount usually runs inside a command substitution, so T1R_ESP_MOUNTED is set in a subshell
# and never reaches the process that exits; the mount directory under $T1R_STATE is the tool's
# own, so whatever is mounted there is ours to release, variable or not.
esp_release() {
  local mp=$T1R_STATE/esp
  [[ -n "${T1R_ESP_MOUNTED:-}" ]] && { umount "$T1R_ESP_MOUNTED" 2>/dev/null || true; T1R_ESP_MOUNTED=; }
  if command -v findmnt >/dev/null 2>&1 && findmnt -rno TARGET "$mp" >/dev/null 2>&1; then
    umount "$mp" 2>/dev/null || warn "could not unmount the ESP at $mp; run: umount $mp"
  fi
  return 0
}

# esp_is_writable MOUNTPOINT: rw vfat mount that root can write to.
esp_is_writable() {
  local mp=${1:?} opts
  opts=$(findmnt -rno FSTYPE,OPTIONS "$mp" 2>/dev/null) || return 1
  case "$opts" in vfat\ *rw*) ;; *) return 1;; esac
  [[ -w "$mp" ]]
}

# ----- FRST ACPI method ----------------------------------------------------------------
# frst_method: full path of the T1 reset method from the AML tables under $T1R_ACPI_TABLES.
# Empty when python3 or readable tables are missing. Never calls anything.
frst_method() {
  local walker=$T1R_ROOT/tools/acpi-method-path.py
  local -a tables=()
  local t out
  command -v python3 >/dev/null 2>&1 || return 0
  [[ -r "$walker" ]] || return 0
  [[ -r "$T1R_ACPI_TABLES/DSDT" ]] && tables+=("$T1R_ACPI_TABLES/DSDT")
  while IFS= read -r t; do [[ -r "$t" ]] && tables+=("$t"); done < <(find "$T1R_ACPI_TABLES" -maxdepth 1 -name 'SSDT*' 2>/dev/null | sort -V)
  [[ "${#tables[@]}" -gt 0 ]] || return 0
  out=$(python3 "$walker" --method FRST "${tables[@]}" 2>/dev/null) || return 0
  local -a cands=() xhc=()
  mapfile -t cands < <(printf '%s\n' "$out" | sed '/^$/d' | sort -u)
  [[ "${#cands[@]}" -gt 0 ]] || return 0
  # An operator may pin the method (T1R_FRST_METHOD in t1-revive.conf); it must be one the
  # tables actually define.
  if [[ -n "${T1R_FRST_METHOD:-}" ]]; then
    for t in "${cands[@]}"; do [[ "$t" = "$T1R_FRST_METHOD" ]] && { printf '%s\n' "$t"; return 0; }; done
    warn "T1R_FRST_METHOD is not an FRST method defined by this machine's ACPI tables; ignoring it"
  fi
  if [[ "${#cands[@]}" = 1 ]]; then printf '%s\n' "${cands[0]}"; return 0; fi
  # Several candidates: accept only a unique one under an xHCI controller node (where the T1
  # hangs). Anything else is refused. A reset method is never guessed.
  for t in "${cands[@]}"; do [[ "$t" =~ (^|\.)XHC[0-9]*\. ]] && xhc+=("$t"); done
  if [[ "${#xhc[@]}" = 1 ]]; then printf '%s\n' "${xhc[0]}"; return 0; fi
  warn "${#cands[@]} FRST methods in the ACPI tables (${#xhc[@]} under an xHCI node); refusing to guess. Pin one with T1R_FRST_METHOD in t1-revive.conf after reading the tables"
  return 0
}
