#!/usr/bin/env bash
# lib/cmd-preflight.sh - cmd_preflight [--local] [--install]
#
# Ported from regen-preflight.sh and toolkit-go.sh step 2. Checks everything the regeneration
# needs WITHOUT touching the T1. Prints "  ok  ..." / "  NO  ..." lines and a summary.
# Exit: 0 ready, 3 problems, 4 unsupported model, 7 reboot needed (kernel changed).
#
# shellcheck shell=bash

_pf_ok=0; _pf_bad=0; _pf_reboot=0
pf_ok()   { printf '  ok  %s\n' "$*"; _pf_ok=$((_pf_ok + 1)); }
pf_no()   { printf '  NO  %s\n' "$*"; _pf_bad=$((_pf_bad + 1)); }
pf_head() { printf '\n%s\n' "$*"; }

# _pf_avail_gb DIR: free space in GiB of DIR or its nearest existing parent
_pf_avail_gb() {
  local d=$1 b
  while [[ ! -d "$d" ]] && [[ "$d" != / ]]; do d=$(dirname "$d"); done
  b=$(df --output=avail -B1 "$d" 2>/dev/null | tail -1 | tr -d ' ')
  printf '%s\n' "$(( ${b:-0} / 1024 / 1024 / 1024 ))"
}

_pf_tcp() {  # _pf_tcp HOST PORT: name resolution + TCP connect only (Apple's endpoints reject curl)
  local h=$1 p=$2 ip
  ip=$(getent ahosts "$h" 2>/dev/null | awk '{print $1; exit}')
  [[ -n "$ip" ]] || return 1
  timeout 6 bash -c "exec 3<>/dev/tcp/$h/$p" 2>/dev/null
}

cmd_preflight() {
  local local_only=0 do_install=0 a is_root=0 model status t1 cfg esp dev mp mounted=
  for a in "$@"; do
    case "$a" in
      --local) local_only=1;;
      --install) do_install=1;;
      -h|--help) echo "usage: t1-revive preflight [--local] [--install]"; return 0;;
      *) echo "preflight: unknown flag $a" >&2; return 2;;
    esac
  done
  _pf_ok=0; _pf_bad=0; _pf_reboot=0
  [[ "${EUID:-$(id -u)}" = 0 ]] && is_root=1
  if [[ "$is_root" = 1 ]]; then ensure_dirs || warn "could not create $T1R_STATE/$T1R_LOG/$T1R_CACHE"; fi
  open_log preflight || true
  show "t1-revive $(version) preflight (nothing touches the T1)"

  pf_head "privileges"
  if [[ "$is_root" = 1 ]]; then pf_ok "running as root"; else pf_no "not running as root: sudo t1-revive preflight (several checks below need it)"; fi

  pf_head "model and T1"
  model=$(model_id); status=$(model_status "$model")
  case "$status" in
    tested) pf_ok "model $model (the proven machine)";;
    untested)
      pf_ok "model $model (a T1 Mac, but the sequence is proven on the MacBookPro14,3 only)"
      warn "untested model: proceed with care and report the result (t1-revive report)";;
    *)
      pf_no "model '$model' is not a T1 MacBook Pro; refusing"
      printf '\n%d ok, %d problems\n' "$_pf_ok" "$_pf_bad"
      diag step=preflight result=refused model_status=unsupported
      show "This machine is not a T1 MacBook Pro; t1-revive refuses to go further."
      return 4;;
  esac
  t1=$(t1_state); cfg=$(t1_config)
  case "$t1" in
    recovery) pf_ok "T1 in recovery (05ac:1281): the starting point for a regeneration";;
    booted) pf_ok "T1 booted (05ac:8600, USB configuration ${cfg:-?}); regenerate resets it first if the ESP has no firmware files";;
    *) pf_no "no T1 on the USB bus (05ac:1281 or 05ac:8600 expected); a full power cycle usually brings it back";;
  esac

  pf_head "network"
  if [[ "$local_only" = 1 ]]; then
    pf_ok "network checks skipped (--local)"
  else
    if ip route 2>/dev/null | grep -q '^default'; then pf_ok "default route present"; else pf_no "no default route: connect to the network first (Wi-Fi on a BCM43602 needs its NVRAM file; see the install-stick README)"; fi
    for a in gs.apple.com swcdn.apple.com; do
      if _pf_tcp "$a" 443; then pf_ok "$a:443 reachable"; else pf_no "$a:443 unreachable (DNS or TCP)"; fi
    done
  fi

  pf_head "packages and kernel ($(distro_id))"
  if [[ "$(distro_family)" = arch ]]; then
    if [[ "$do_install" = 1 ]] && [[ "$is_root" = 1 ]]; then
      if distro_needs_sync; then
        if distro_sync_and_upgrade; then pf_ok "system synced and upgraded"; else pf_no "system upgrade failed (see pacman's output above; or run omarchy-update / pacman -Syu and retry)"; fi
      fi
    fi
    if distro_kernel_matches; then pf_ok "running kernel $(uname -r) is the installed one"
    else pf_no "the installed kernel differs from the running $(uname -r): reboot, then run this again"; _pf_reboot=1; fi
    if [[ "$do_install" = 1 ]] && [[ "$is_root" = 1 ]] && [[ "$_pf_reboot" = 0 ]]; then
      # shellcheck disable=SC2086
      if distro_install $T1R_ARCH_PKGS; then pf_ok "packages: $T1R_ARCH_PKGS"; else pf_no "package install failed: $T1R_ARCH_PKGS (fresh install with only the offline package DB? rerun with --install after 'pacman -Sy')"; fi
    else
      local missing='' p
      for p in $T1R_ARCH_PKGS; do distro_installed "$p" || missing="$missing $p"; done
      if [[ -z "$missing" ]]; then pf_ok "packages: $T1R_ARCH_PKGS"; else pf_no "missing packages:${missing} (sudo t1-revive preflight --install)"; fi
    fi
  else
    pf_no "package checks are implemented for Arch-based systems only; make sure the equivalents of '$T1R_ARCH_PKGS' are installed"
  fi
  if distro_headers_present; then pf_ok "kernel headers for $(uname -r)"; else pf_no "no kernel headers for $(uname -r) (dkms cannot build acpi_call)"; fi
  if [[ "$is_root" = 1 ]] && [[ "$T1R_DRY_RUN" != 1 ]]; then modprobe acpi_call 2>/dev/null || true; fi
  if [[ -e /proc/acpi/call ]]; then pf_ok "acpi_call loaded (/proc/acpi/call): the T1 reset is available"
  elif [[ "$is_root" = 1 ]]; then pf_no "acpi_call not loaded: the T1 reset (FRST) needs it (check: dkms status; journalctl -k | grep acpi_call)"
  else pf_no "acpi_call not loaded (as root, preflight loads it: sudo t1-revive preflight)"; fi

  pf_head "restore toolchain ($T1R_PREFIX)"
  local libs="$T1R_PREFIX/lib:$T1R_PREFIX/lib64" b out
  for b in bin/idevicerestore bin/irecovery bin/plistutil sbin/usbmuxd; do
    if [[ -x "$T1R_PREFIX/$b" ]] && LD_LIBRARY_PATH=$libs "$T1R_PREFIX/$b" --version >/dev/null 2>&1; then pf_ok "$b runs"
    elif [[ -x "$T1R_PREFIX/$b" ]]; then
      out=$(LD_LIBRARY_PATH=$libs ldd "$T1R_PREFIX/$b" 2>/dev/null | awk '/not found/{print $1}' | paste -sd' ')
      pf_no "$b does not run (${out:-no missing libraries reported}); install the packages above"
    else pf_no "$b missing: build the patched stack (build.sh) or install the package"; fi
  done
  if [[ -x "$T1R_PREFIX/bin/idevicerestore" ]]; then
    # grep the file directly: `strings | grep -q` dies of SIGPIPE under pipefail on a real-size binary
    if grep -qaF 'T1: EmbeddedOS restore options applied' "$T1R_PREFIX/bin/idevicerestore" 2>/dev/null; then pf_ok "idevicerestore carries the T1 patches"
    else pf_no "idevicerestore is not the patched build (no T1 marker string)"; fi
  fi

  pf_head "firmware"
  if declare -F firmware_bundle_dir >/dev/null 2>&1; then
    out=$(firmware_bundle_dir 2>/dev/null || true)
    if [[ -n "$out" ]] && [[ -f "$out/Contents/Resources/BuildManifest.plist" ]]; then pf_ok "firmware bundle present in the cache"
    elif [[ "$local_only" = 1 ]]; then pf_no "firmware bundle not in the cache and --local given: regenerate cannot fetch it"
    else pf_ok "firmware bundle not cached yet (regenerate fetches and verifies it from Apple's CDN)"; fi
  else
    pf_ok "firmware: not checked (lib/firmware.sh not loaded)"
  fi

  pf_head "EFI system partition"
  if esp=$(esp_select); then
    read -r dev mp <<<"$esp"
    out=$(esp_candidates | wc -l)
    if [[ "$out" -gt 1 ]]; then
      note "$out EFI system partitions; $dev chosen: $(esp_select --why)"
      esp_candidates | awk -v d="$dev" '$1 != d {printf "  not chosen: %s (mounted: %s, EFI/APPLE: %s)\n", $1, $2, $3}' | while IFS= read -r out; do note "$out"; done
    fi
    if [[ "$mp" != "-" ]]; then mounted=$mp
    elif [[ "$is_root" = 1 ]] && [[ "$T1R_DRY_RUN" != 1 ]]; then mounted=$(esp_mount "$dev" 2>/dev/null || true); fi
    if [[ -n "$mounted" ]]; then
      if [[ "$is_root" = 1 ]]; then
        if esp_is_writable "$mounted"; then pf_ok "ESP $dev mounted rw (vfat) at $mounted"; else pf_no "ESP $dev at $mounted is not a writable vfat mount"; fi
      else pf_ok "ESP $dev at $mounted (writability needs root)"; fi
      if [[ -d "$mounted/EFI/APPLE/EMBEDDEDOS" ]]; then
        pf_ok "EFI/APPLE/EMBEDDEDOS present: this ESP was not wiped; run 't1-revive backup' before anything else"
        [[ -f "$mounted/EFI/APPLE/EMBEDDEDOS/FDRData" ]] && note "FDRData is there: if the T1 is booted, no regeneration is needed"
      elif [[ -d "$mounted/EFI/APPLE" ]]; then
        pf_ok "EFI/APPLE present but no EMBEDDEDOS folder (partially wiped); 't1-revive backup' saves what is left"
      elif [[ "$is_root" = 1 ]] || [[ -r "$mounted" ]]; then
        if [[ "$(esp_candidates | wc -l)" -gt 1 ]]; then
          pf_ok "no EFI/APPLE on $dev; the other EFI system partition(s) listed above hold none either (or could not be looked at): a wiped ESP"
        else pf_ok "no EFI/APPLE on the ESP (a wiped ESP, as expected); nothing to back up"; fi
      else
        pf_ok "EFI/APPLE presence: not readable as a normal user"
      fi
      if [[ "$(_pf_avail_gb "$mounted")" = 0 ]]; then
        out=$(df --output=avail -B1 "$mounted" 2>/dev/null | tail -1 | tr -d ' ')
        if [[ "${out:-0}" -ge 33554432 ]]; then pf_ok "ESP free space: $(( ${out:-0} / 1024 / 1024 )) MiB"; else pf_no "ESP free space below 32 MiB ($(( ${out:-0} / 1024 / 1024 )) MiB)"; fi
      else pf_ok "ESP free space: $(_pf_avail_gb "$mounted") GiB"; fi
    else
      pf_ok "ESP $dev found (not mounted; stage mounts it under $T1R_STATE/esp)"
    fi
  else
    out=$(esp_candidates | wc -l)
    if [[ "$out" = 0 ]]; then pf_no "no EFI system partition found (partition type $T1R_ESP_PARTTYPE)"
    else pf_no "$out EFI system partitions and none stands out (exactly one internal one with EFI/APPLE, else exactly one mounted at /boot or /efi): $(esp_candidates | awk '{printf "%s@%s(EFI/APPLE:%s) ", $1, $2, $3}'); pin one with T1R_ESP_DEV in $T1R_CONF/t1-revive.conf"; fi
  fi

  pf_head "T1 reset method"
  out=$(frst_method)
  if [[ -n "$out" ]]; then pf_ok "FRST method found in the ACPI tables: $out"
  elif [[ "$is_root" = 0 ]] && [[ ! -r "$T1R_ACPI_TABLES/DSDT" ]]; then pf_no "FRST method: ACPI tables not readable as a normal user (run as root)"
  elif ! command -v python3 >/dev/null 2>&1; then pf_no "FRST method: python3 is needed to read the ACPI tables"
  else pf_no "FRST method not found in the ACPI tables under $T1R_ACPI_TABLES; regenerate refuses without it"; fi

  pf_head "services and state"
  if systemctl is-active --quiet usbmuxd 2>/dev/null; then pf_no "system usbmuxd is running: systemctl disable --now usbmuxd (the restore runs its own)"; else pf_ok "no system usbmuxd"; fi
  if distro_installed t1bridge 2>/dev/null; then pf_ok "t1bridge installed ($(distro_pkg_version t1bridge)); regenerate unloads its modules while the T1 is in recovery and hands the T1 back at the end"
  else pf_ok "t1bridge not installed (install it after the regeneration for Touch Bar and Touch ID)"; fi
  if lsmod 2>/dev/null | grep -q -E '^(t1_cfgsel|apple_dfr_cfgsel) '; then note "a USB configuration selector module is loaded; regenerate unloads it before touching the T1"; fi
  if dir_nonempty "$T1R_STATE/private"; then
    pf_ok "prior private state under $T1R_STATE/private"
    warn "a previous run left state: resume with 't1-revive regenerate --from STEP', or move $T1R_STATE/private aside for a from-nothing run"
  elif [[ "$is_root" = 1 ]]; then pf_ok "no prior private state: from-nothing regeneration"
  else pf_ok "private state: not readable as a normal user"; fi
  for a in "$T1R_STATE" "$T1R_CACHE"; do
    out=$(_pf_avail_gb "$a")
    if [[ "$out" -ge 2 ]]; then pf_ok "$out GiB free for $a"; else pf_no "less than 2 GiB free for $a ($out GiB)"; fi
  done

  printf '\n%d ok, %d problems\n' "$_pf_ok" "$_pf_bad"
  if [[ "$_pf_reboot" = 1 ]]; then
    show "Reboot, then run 't1-revive preflight' again."
    diag step=preflight result=reboot ok="$_pf_ok" problems="$_pf_bad"
    return 7
  fi
  if [[ "$_pf_bad" = 0 ]]; then
    show "Ready. Next: sudo t1-revive backup (if EFI/APPLE exists), then sudo t1-revive regenerate"
    diag step=preflight result=ok ok="$_pf_ok" problems=0 t1="$t1" model_status="$status"
    return 0
  fi
  show "Fix the NO lines first."
  diag step=preflight result=error code=3 ok="$_pf_ok" problems="$_pf_bad" t1="$t1" model_status="$status"
  return 3
}
