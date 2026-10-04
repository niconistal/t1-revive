# lib/steps/common-steps.sh - pieces shared by the restore steps and the
# regenerate/stage/handover commands. Sourced by bin/t1-revive after
# lib/common.sh and lib/discover.sh; defines functions only.
#
# Everything that touches the device, the ESP, the kernel (modprobe, sysfs
# writes, systemd units) or the network goes through `dry` / `dry_write` so
# T1R_DRY_RUN=1 prints the exact command instead of running it.
# shellcheck shell=bash

# ---------------------------------------------------------------- locations --

# priv_dir: the 0700 private directory (FDR store, memboot, ticket, raw logs).
# Original: install -d -o root -g root -m 700 <state dir> and <state dir>/private
priv_dir() {
  local p="${T1R_STATE:?}/private"
  install -d -m 700 "$T1R_STATE" || die 1 "cannot create $T1R_STATE"
  install -d -m 700 "$p" || die 1 "cannot create $p"
  printf '%s\n' "$p"
}

# set_aside_artifacts STEP NAME...: move the named files a previous attempt left in
# private/ into private/attempts/<stamp>-STEP/ before a restore starts, so the gates after
# the restore can only see files this attempt produced. Nothing is deleted: the old files
# stay 0600 under the 0700 private directory for inspection. A dry run prints the moves.
set_aside_artifacts() {
  local step=${1:?set_aside_artifacts STEP NAME...} p n dest=
  shift
  p="${T1R_STATE:?}/private"
  for n in "$@"; do
    [ -e "$p/$n" ] || continue
    if [ -z "$dest" ]; then
      dest="$p/attempts/$(date +%Y%m%d-%H%M%S)-$step"
      if is_dry; then note "(dry) install -d -m 700 $dest"
      else install -d -m 700 "$p/attempts" "$dest" || die 1 "cannot create $dest"; fi
    fi
    note "setting aside $n from an earlier attempt -> private/attempts/${dest##*/}/"
    dry mv -f -- "$p/$n" "$dest/$n" || die 1 "cannot move $p/$n aside"
  done
  return 0
}

# fdr_replay_matches ORIGINAL REPLAYED: true when the replayed FDR store is the provisioned
# one. Byte-identical is what every hardware run so far produced. A store that differs in
# bytes but parses to the same plist (plistutil's XML rendering of both is identical) also
# counts, since only the content is replayed to the device.
fdr_replay_matches() {
  local a=${1:?} b=${2:?} xa xb rc
  [ -s "$a" ] && [ -s "$b" ] || return 1
  cmp -s -- "$a" "$b" && return 0
  xa=$(umask 077; mktemp "${T1R_STATE:?}/private/.fdr-a.XXXXXX") || return 1
  xb=$(umask 077; mktemp "${T1R_STATE:?}/private/.fdr-b.XXXXXX") || { rm -f -- "$xa"; return 1; }
  rc=1
  if LD_LIBRARY_PATH="${T1R_LIBS:-}" "${T1R_PLISTUTIL:?}" -i "$a" -o "$xa" -f xml >/dev/null 2>&1 \
     && LD_LIBRARY_PATH="${T1R_LIBS:-}" "${T1R_PLISTUTIL:?}" -i "$b" -o "$xb" -f xml >/dev/null 2>&1 \
     && [ -s "$xa" ] && cmp -s -- "$xa" "$xb"; then
    rc=0
  fi
  rm -f -- "$xa" "$xb"
  return "$rc"
}

# prefix_env: the patched-stack locations. LD_LIBRARY_PATH is NOT exported
# globally: the proven scripts pass it per command, and every idevicerestore,
# usbmuxd and plistutil call below does the same with $T1R_LIBS.
prefix_env() {
  : "${T1R_PREFIX:?T1R_PREFIX unset}"
  T1R_LIBS="$T1R_PREFIX/lib:$T1R_PREFIX/lib64"
  T1R_IDR="$T1R_PREFIX/bin/idevicerestore"
  T1R_MUX="$T1R_PREFIX/sbin/usbmuxd"
  T1R_PLISTUTIL="$T1R_PREFIX/bin/plistutil"
  T1R_MUX_UNIT=t1-usbmuxd
  T1R_MUX_SOCK=/run/usbmuxd
  export T1R_LIBS T1R_IDR T1R_MUX T1R_PLISTUTIL T1R_MUX_UNIT T1R_MUX_SOCK
}

# firmware_dir: Contents/Resources of the extracted bundle (lib/firmware.sh).
# In a dry run without a cached package firmware_ensure prints nothing; the
# expected location is used so the trace can continue.
firmware_dir() {
  declare -F firmware_ensure >/dev/null || die 1 "firmware module missing (lib/firmware.sh)"
  local fw; fw=$(firmware_ensure) || die 6 "firmware bundle not available"
  if [ -z "$fw" ]; then
    is_dry || die 6 "firmware bundle not available"
    if declare -F _fw_bundle_root >/dev/null; then fw="$(_fw_bundle_root)/Contents/Resources"
    else fw="${T1R_CACHE:-/var/cache/t1-revive}/firmware/bundle/Contents/Resources"; fi
    note "(dry) firmware bundle not cached yet; assuming $fw"
  fi
  printf '%s\n' "$fw"
}

# bundle_ok DIR: BuildManifest.plist is present (dry run: only note if not).
bundle_ok() {
  [ -f "$1/BuildManifest.plist" ] && return 0
  if is_dry; then note "(dry) firmware bundle not present at $1"; return 0; fi
  die 6 "firmware bundle missing at $1"
}

# ------------------------------------------------------------------ dry run --

is_dry() { [ "${T1R_DRY_RUN:-0}" = 1 ]; }

# dry CMD...: run CMD, or in T1R_DRY_RUN=1 print it. Used for every command
# that talks to the device, the ESP, systemd, modules or the network.
dry() {
  if is_dry; then note "(dry) $(printf '%q ' "$@")"; return 0; fi
  "$@"
}

# dry_q CMD...: dry() for the proven scripts' `CMD 2>/dev/null` calls. Writing the
# redirection at the call site would swallow the "(dry)" trace line as well (note goes
# to stderr), so the wrapper discards only the real command's stderr.
dry_q() {
  if is_dry; then note "(dry) $(printf '%q ' "$@")"; return 0; fi
  "$@" 2>/dev/null
}

# dry_write FILE FORMAT ARGS...: printf FORMAT ARGS > FILE (sysfs, /proc/acpi/call).
dry_write() {
  local f=$1 fmt=$2; shift 2
  if is_dry; then note "(dry) printf '$fmt' $* > $f"; return 0; fi
  # shellcheck disable=SC2059
  printf "$fmt" "$@" > "$f"
}

# dry_sleep SECONDS: the proven waits, printed instead of slept in a dry run.
dry_sleep() { if is_dry; then note "(dry) sleep $1"; else sleep "$1"; fi; }

# dry_wait STATE SECONDS: wait_t1, or in a dry run print the expectation.
dry_wait() {
  if is_dry; then note "(dry) wait up to $2 s for T1 state $1"; return 0; fi
  wait_t1 "$1" "$2"
}

# t1_require STATE CODE MSG: die CODE MSG unless t1_state = STATE. In a dry
# run only report (nothing ran, so the state cannot have changed).
t1_require() {
  local want=$1 code=$2 msg=$3 have; have=$(t1_state)
  [ "$have" = "$want" ] && return 0
  if is_dry; then note "(dry) expect T1 state $want (is: $have)"; return 0; fi
  die "$code" "$msg (T1 is: $have)"
}

# t1_forbid STATE CODE MSG: die CODE MSG if t1_state = STATE (dry: report).
t1_forbid() {
  local bad=$1 code=$2 msg=$3 have; have=$(t1_state)
  [ "$have" = "$bad" ] || return 0
  if is_dry; then note "(dry) T1 must not be $bad (is: $have)"; return 0; fi
  die "$code" "$msg"
}

# expect_file FILE CODE MSG: die unless FILE is non-empty (dry: report).
expect_file() {
  [ -s "$1" ] && return 0
  if is_dry; then note "(dry) expect file ${1##*/}"; return 0; fi
  die "$2" "$3"
}

# file_size FILE: size in bytes, or ? when absent (dry runs).
file_size() { stat -c %s "$1" 2>/dev/null || printf '?'; }

# ------------------------------------------------------------ usb / sysfs --

# t1_product: 8600 | 1281 | none, the vocabulary of the proven scripts.
t1_product() {
  case "$(t1_state)" in booted) echo 8600;; recovery) echo 1281;; *) echo none;; esac
}

# usb_report: "=== T1 USB state now ===" block of the provision and personalize
# steps (bus id and pid).
usb_report() {
  local d v
  for d in "${T1R_SYSFS:-/sys}"/bus/usb/devices/*/; do
    v=$(cat "$d/idVendor" 2>/dev/null)
    [ "$v" = "05ac" ] && note "$(basename "$d"): $v:$(cat "$d/idProduct" 2>/dev/null)"
  done
  return 0
}

# ---------------------------------------------------------------- usbmuxd --

# start_usbmuxd: the private patched usbmuxd as a transient unit, exactly as
# the provision and personalize steps start it. Needs prefix_env and priv_dir.
start_usbmuxd() {
  local priv=$1
  dry_q systemctl stop "$T1R_MUX_UNIT.service"
  install -m 600 /dev/null "$priv/usbmuxd.private.log"
  dry systemd-run --quiet --collect --unit="$T1R_MUX_UNIT" \
    --property=Type=simple \
    --property=StandardOutput=null --property=StandardError=null \
    env LD_LIBRARY_PATH="$T1R_LIBS" \
    "$T1R_MUX" -f -v -U root -l "$priv/usbmuxd.private.log" \
    || die 1 "could not start private usbmuxd"
  dry_sleep 2
  if ! is_dry; then
    systemctl is-active --quiet "$T1R_MUX_UNIT.service" || die 1 "private usbmuxd did not stay up"
    [ -S "$T1R_MUX_SOCK" ] && note "private usbmuxd socket ready"
  fi
  return 0
}

# stop_usbmuxd: systemctl stop t1-usbmuxd.service 2>/dev/null
stop_usbmuxd() { dry_q systemctl stop "$T1R_MUX_UNIT.service"; return 0; }

# no_system_usbmuxd CODE: the distribution's usbmuxd must not compete.
no_system_usbmuxd() {
  systemctl is-active --quiet usbmuxd 2>/dev/null && die "${1:-3}" "system usbmuxd is running; stop it first (systemctl disable --now usbmuxd)"
  return 0
}

# ------------------------------------------------------------ step records --

# step_marker_dir: $T1R_STATE/private/steps
step_marker_dir() { printf '%s\n' "${T1R_STATE:?}/private/steps"; }

# step_done NAME: true if NAME finished successfully in some run.
step_done() { [ -f "$(step_marker_dir)/$1.done" ]; }

T1R_STEP_ORDER="provision reset-1 personalize reset-2 boot stage handover"
# step_invalidate_after NAME: remove the markers of every step after NAME in chain order.
step_invalidate_after() {
  local after=0 s
  for s in $T1R_STEP_ORDER; do
    if [ "$after" = 1 ]; then rm -f "$(step_marker_dir)/$s.done"; fi
    [ "$s" = "$1" ] && after=1
  done
  return 0
}

# step_banner DEMO_TEXT NORMAL_TEXT: one-shot's `[ demo ] && say A || say B`.
step_banner() {
  if [ "${T1R_DEMO:-0}" = 1 ]; then show ""; show "$1"; else say "$2"; fi
}

# _scr FORMAT ARGS...: the demo spinner's screen channel (partial lines, so it
# cannot go through show). open_log keeps the terminal on $T1R_SCREEN_FD
# (fd 3, as one-shot.sh did); else the tty, else stdout.
_scr() {
  local fd=${T1R_SCREEN_FD:-}
  # shellcheck disable=SC2059
  if [ -n "$fd" ] && { true >&"$fd"; } 2>/dev/null; then printf "$@" >&"$fd"
  elif [ -w /dev/tty ]; then printf "$@" >/dev/tty
  else printf "$@"; fi
}

# spin PID MSG: one-shot.sh's demo spinner (with the "connected to Apple" tick).
spin() {
  local pid=$1 msg=$2 i=0 apple=0; local f='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$apple" = 0 ] && ss -Htn state established 2>/dev/null | awk '{print $4}' | grep -q '^17\.'; then
      apple=1; _scr '\r  ✓ connected to Apple (17.x.x.x)          \n'
    fi
    _scr '\r  %s %s' "${f:i%10:1}" "$msg"; i=$((i+1)); sleep 0.2
  done
  wait "$pid"; local rc=$?
  local mark=✗; [ "$rc" = 0 ] && mark=✓
  _scr '\r  %s %s\n' "$mark" "$msg"
  return "$rc"
}

# run MSG CMD...: one-shot.sh's run(). Demo: background + spinner. Otherwise
# print MSG and run CMD in a subshell (the originals ran a child script, so a
# `die` inside a step ends the step, not the chain).
run() {
  local msg=$1; shift
  if [ "${T1R_DEMO:-0}" = 1 ]; then
    T1R_IN_STEP=1 "$@" & spin $! "$msg"
  else
    note "$msg"; ( T1R_IN_STEP=1; export T1R_IN_STEP; "$@" )
  fi
}

# run_step NAME FN [MSG [ARGS...]]: run FN ARGS through run(), time it, diag
# it, and record $T1R_STATE/private/steps/NAME.done on success. Appends to
# T1R_STEP_TIMES.
declare -a T1R_STEP_TIMES=()
run_step() {
  local name=$1 fn=$2 msg=${3:-$1} t0 rc elapsed
  if [ $# -ge 3 ]; then shift 3; else shift $#; fi
  t0=$(date +%s)
  diag step="$name" result=start
  run "$msg" "$fn" "$@"; rc=$?
  elapsed=$(( $(date +%s) - t0 ))
  if [ "$rc" = 0 ]; then
    # A dry run must never leave a marker behind: `t1-revive stage` reads them as proof
    # that the T1 really booted from the personalised image.
    if is_dry; then note "(dry) would record step marker $name.done"
    else
      install -d -m 700 "$(step_marker_dir)" && date +%s > "$(step_marker_dir)/$name.done"
      # A step that ran again invalidates every downstream proof: a new image must not be
      # staged on the strength of an older boot marker.
      step_invalidate_after "$name"
    fi
    diag step="$name" result=ok elapsed="$elapsed"
  else
    diag step="$name" result=error code="$rc" t1="$(t1_state)" elapsed="$elapsed"
  fi
  T1R_STEP_TIMES+=("$name $elapsed")
  return "$rc"
}

# timing_summary: one line per step and the total.
timing_summary() {
  local e total=0 n s
  [ ${#T1R_STEP_TIMES[@]} -gt 0 ] || return 0
  for e in "${T1R_STEP_TIMES[@]}"; do
    n=${e% *}; s=${e#* }; total=$((total + s))
    note "$(printf '%-12s %4d s' "$n" "$s")"
  done
  note "$(printf '%-12s %4d s (%d min %d s)' total "$total" $((total/60)) $((total%60)))"
}

# lock_once: lock_acquire unless this process already holds the lock (the
# stage and handover commands run inside cmd_regenerate too).
lock_once() {
  [ "${T1R_LOCK_HELD:-0}" = 1 ] && return 0
  lock_acquire
  T1R_LOCK_HELD=1; export T1R_LOCK_HELD
}

# fallback_text STEP: the resume instruction printed with every step failure.
fallback_text() {
  printf 'Fallback: full shutdown, wait 20 s, power on, then: t1-revive regenerate --from %s' "$1"
}

# esp_resolve: the single ESP as "DEVICE MOUNTPOINT", mounting it when it is not
# mounted (esp_mount only prints in a dry run). die 4 when it is not unambiguous.
# Shared by cmd_regenerate (backup rule) and cmd_stage (staging target).
# Returns 1 (after a warning) instead of dying: callers run it in a command substitution, where
# an exit would only end the subshell and leave the caller with an empty mountpoint.
esp_resolve() {
  local dev='' mnt='' sel
  sel=$(esp_select) || { warn "cannot identify a single EFI System Partition (see: t1-revive preflight)"; return 1; }
  read -r dev mnt <<<"$sel"
  [ -n "$dev" ] || { warn "cannot identify a single EFI System Partition (see: t1-revive preflight)"; return 1; }
  if [ -z "$mnt" ] || [ "$mnt" = "-" ]; then
    mnt=$(esp_mount "$dev" | tail -1) || { warn "could not mount the ESP $dev"; return 1; }
    [ -n "$mnt" ] || { warn "could not mount the ESP $dev"; return 1; }
  fi
  printf '%s %s\n' "$dev" "$mnt"
}

# esp_resolve_or_die: the checked form for the commands; sets ESP_DEV and ESP_MNT.
esp_resolve_or_die() {
  local line
  line=$(esp_resolve) || die 4 "cannot identify a single EFI System Partition (see: t1-revive preflight)"
  line=${line##*$'\n'}
  read -r ESP_DEV ESP_MNT <<<"$line"; export ESP_DEV ESP_MNT
  [ -n "${ESP_MNT:-}" ] || die 4 "cannot identify a single EFI System Partition (see: t1-revive preflight)"
}

# open_log_once NAME: start the command log unless one is already open (the stage and
# handover commands also run inside cmd_regenerate, which opened one already).
open_log_once() {
  [ -n "${T1R_LOGFILE:-}" ] && return 0
  ensure_dirs || warn "cannot create $T1R_STATE / $T1R_LOG / $T1R_CACHE"
  open_log "$1" || true
  return 0
}

# redact_restore: the on-screen filter the proven scripts put after tee
# (the log filter in common.sh redacts again; this one also covers the
# restore protocol's tag names).
# redact_restore: the restore pipelines' filter; the same rules now live in common.sh's redact.
redact_restore() { redact; }

# restore_report RUNNER_LOG: the "=== result ===" lines shared by the passes.
restore_report() {
  local log=$1 rc=$2
  if is_dry; then note "(dry) result section skipped (no restore ran)"; return 0; fi
  note "idevicerestore exit: $rc"
  if grep -qa "Status: Restore Finished" "$log"; then note "Restore Finished: yes"; else note "Restore Finished: NO"; fi
  if grep -qa "Unknown data request" "$log"; then
    note "!! unknown data requests were seen:"
    grep -ao "Unknown data request '[A-Za-z0-9]*'" "$log" | sort -u | sed 's/^/     /'
  fi
  return 0
}

# check_idevicerestore MARKER: the patched binary is present, runs, and
# carries the T1 implementation (provision/personalize: "T1: EmbeddedOS restore
# options applied"; boot: "T1: phase 14 mode", the marker string the vendored
# binary carries).
check_idevicerestore() {
  local marker=$1 n
  [ -x "$T1R_IDR" ] || die 3 "idevicerestore not built at $T1R_IDR"
  LD_LIBRARY_PATH="$T1R_LIBS" "$T1R_IDR" --version >/dev/null 2>&1 || die 3 "idevicerestore will not run"
  n=$(grep -aFc -- "$marker" "$T1R_IDR" 2>/dev/null || true)
  [ "${n:-0}" -ge 1 ] || die 3 "binary does not contain the T1 implementation ($marker)"
}
