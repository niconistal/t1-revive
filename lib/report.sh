# lib/report.sh — cmd_report: the redacted, structured diagnostic bundle.
#
# Sourced by bin/t1-revive after lib/common.sh. Defines functions only; nothing runs at
# source time. Depends on the lib/common.sh contract (redact, version, t1_state, t1_config,
# kver_normalize, die, warn) and on lib/discover.sh (model_id, model_status, esp_candidates,
# frst_method). Missing discover functions degrade to "unavailable" lines.
#
# Output contract (docs/diagnostics.md): every line is either "key: value" or a
# "t1-revive-diagnostic v=1 ..." line. Sections appear in a fixed order. The last line is
# "report-sha256: <hex>" over everything above it, so a pasted report can be checked for
# truncation with:  head -n -1 report.txt | sha256sum
#
# Privacy: the whole body passes through `redact`. The report never reads FDRData, the
# memboot image, tickets, keybags or any file under EFI/APPLE; it stats them for size only.
# It works without root and says which sections need root instead of failing.

report_usage() {
  cat <<'USAGE' >&2
usage: t1-revive report [--out FILE] [--since MIN]

  --out FILE    write the bundle to FILE instead of stdout
  --since MIN   only diagnostic lines from the last MIN minutes (default: last 200 lines)

Run it as your own user for a quick look, or with sudo for the complete bundle
(ESP contents, private state names, t1bridge status, the redacted log directory).
USAGE
}

# kv KEY VALUE  — one "key: value" line; empty values print as "-"
report_kv() {
  local v="${2:-}"
  [ -n "$v" ] || v='-'
  printf '%s: %s\n' "$1" "$v"
}

report_have() { type "$1" >/dev/null 2>&1; }

report_is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

# size of a file in KB (rounded), or "-" if not statable
report_kb() {
  local bytes
  bytes=$(stat -c %s -- "$1" 2>/dev/null) || { printf -- '-'; return; }
  local kb=$(( (bytes + 512) / 1024 ))
  [ "$bytes" -gt 0 ] && [ "$kb" -eq 0 ] && kb=1
  printf '%d' "$kb"
}

# yes/no for a path test without ever opening the file
report_yn() { if [ -e "$1" ]; then printf yes; else printf no; fi; }

# --- sections -------------------------------------------------------------------------

report_section_tool() {
  report_kv section tool
  report_kv report-format 1
  report_kv report-time "$(date -u +%Y-%m-%dT%H:%MZ)"
  if report_is_root; then report_kv privileges root; else report_kv privileges user; fi
  local v='-'
  report_have version && v=$(version 2>/dev/null)
  report_kv tool-version "$v"
  report_kv dry-run "${T1R_DRY_RUN:-0}"
  report_kv demo "${T1R_DEMO:-0}"
}

report_section_system() {
  report_kv section system
  local pretty='-' id='-'
  if [ -r /etc/os-release ]; then
    pretty=$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-}")
    id=$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")
  fi
  report_kv distro "$pretty"
  report_kv distro-id "$id"
  local kver
  kver=$(uname -r 2>/dev/null)
  report_kv kernel "$kver"
  # running kernel vs installed kernel package (a mismatch means "reboot needed", exit 7)
  local pkgver='-' match=unknown
  if command -v pacman >/dev/null 2>&1; then
    pkgver=$(pacman -Q linux 2>/dev/null | awk '{print $2}')
    if [ -n "$pkgver" ] && report_have kver_normalize; then
      pkgver=$(printf '%s\n' "$pkgver" | kver_normalize)
      if [ "$pkgver" = "$kver" ]; then match=yes; else match=no; fi
    fi
  fi
  report_kv kernel-pkg "$pkgver"
  report_kv kernel-match "$match"
  if [ -d "/usr/lib/modules/$kver/build" ]; then
    report_kv kernel-headers yes
  else
    report_kv kernel-headers no
  fi
}

report_section_model() {
  report_kv section model
  local id='-' status='-'
  if report_have model_id; then id=$(model_id 2>/dev/null); else id=unavailable; fi
  if [ -n "$id" ] && [ "$id" != unavailable ] && report_have model_status; then
    status=$(model_status "$id" 2>/dev/null)
  fi
  report_kv model "$id"
  report_kv model-status "$status"
}

report_section_t1() {
  report_kv section t1
  local st='-' cfg='-'
  if report_have t1_state; then st=$(t1_state 2>/dev/null); else st=unavailable; fi
  report_kv t1-state "$st"
  if [ "$st" = booted ] && report_have t1_config; then cfg=$(t1_config 2>/dev/null); fi
  report_kv t1-config "$cfg"
}

# one ESP candidate: DEVICE MOUNTPOINT HAS_APPLE
report_esp_one() {
  local dev="$1" mp="${2:-}" has_apple="${3:-}" n="$4"
  report_kv "esp[$n].device" "$dev"
  case "$mp" in ''|-|none|null) mp='' ;; esac
  if [ -n "$mp" ]; then report_kv "esp[$n].mounted" yes; else report_kv "esp[$n].mounted" no; fi
  if [ -z "$mp" ]; then
    # Not mounted: Apple's ESP on a dual-boot Mac. As root, look at it through a read-only
    # probe mount so the bundle can tell an intact machine from a wiped one.
    if report_have esp_with_ro_mount && esp_with_ro_mount "$dev" report_esp_files "$n" 2>/dev/null; then
      report_kv "esp[$n].note" probed-read-only
    else
      report_kv "esp[$n].efi-apple" "${has_apple:-unknown}"
      if report_is_root; then report_kv "esp[$n].note" not-mounted; else report_kv "esp[$n].note" not-mounted-needs-root; fi
    fi
    return
  fi
  if [ ! -r "$mp" ] || [ ! -x "$mp" ]; then
    report_kv "esp[$n].efi-apple" "${has_apple:-unknown}"
    report_kv "esp[$n].note" needs-root
    return
  fi
  report_esp_files "$n" "$mp"
}

# report_esp_files N MOUNTPOINT: the EFI/APPLE fields of one mounted ESP (names and sizes only).
report_esp_files() {
  local n="$1" mp="$2"
  local apple="$mp/EFI/APPLE" eos="$mp/EFI/APPLE/EMBEDDEDOS"
  report_kv "esp[$n].efi-apple" "$(report_yn "$apple")"
  report_kv "esp[$n].embeddedos" "$(report_yn "$eos")"
  local f
  for f in combined.memboot FDRData version.plist; do
    if [ -e "$eos/$f" ]; then
      report_kv "esp[$n].$f" "yes $(report_kb "$eos/$f")KB"
    else
      report_kv "esp[$n].$f" no
    fi
  done
}

report_section_esp() {
  report_kv section esp
  if ! report_have esp_candidates; then
    report_kv esp-candidates unavailable
    return
  fi
  local lines n=0 dev mp has
  lines=$(esp_candidates 2>/dev/null)
  if [ -z "$lines" ]; then
    report_kv esp-candidates 0
    return
  fi
  while read -r dev mp has; do
    [ -n "$dev" ] || continue
    report_esp_one "$dev" "$mp" "$has" "$n"
    n=$((n + 1))
  done <<<"$lines"
  report_kv esp-candidates "$n"
  if report_have esp_select; then
    local sel
    if sel=$(esp_select 2>/dev/null); then
      report_kv esp-selected "${sel%% *}"
      report_kv esp-selected-why "$(esp_select --why 2>/dev/null | tr ' ' '-')"
    else
      report_kv esp-selected ambiguous
    fi
  fi
}

report_section_reset() {
  report_kv section reset
  local sysfs="${T1R_SYSFS:-/sys}"
  if [ -d "$sysfs/module/acpi_call" ]; then
    report_kv acpi-call-loaded yes
  else
    report_kv acpi-call-loaded no
  fi
  local tables="${T1R_ACPI_TABLES:-$sysfs/firmware/acpi/tables}"
  if ! report_have frst_method; then
    report_kv frst-method unavailable
  elif [ ! -r "$tables/DSDT" ] && ! report_is_root; then
    report_kv frst-method needs-root
  else
    local m
    m=$(frst_method 2>/dev/null)
    if [ -n "$m" ]; then report_kv frst-method found; else report_kv frst-method not-found; fi
  fi
}

report_section_state() {
  report_kv section state
  local state="${T1R_STATE:-/var/lib/t1-revive}"
  if [ ! -d "$state" ]; then
    report_kv state-dir absent
    return
  fi
  if [ ! -r "$state" ] || [ ! -x "$state" ]; then
    report_kv state-dir needs-root
    return
  fi
  report_kv state-dir present
  local steps="$state/private/steps" names='' f
  if [ -d "$steps" ] && [ -r "$steps" ]; then
    for f in "$steps"/*; do
      [ -e "$f" ] || continue
      names="$names${names:+ }$(basename -- "$f")"
    done
    report_kv step-markers "${names:-none}"
  else
    report_kv step-markers none
  fi
  local n=0
  for f in "$state"/efi-backup-*; do
    [ -e "$f" ] && n=$((n + 1))
  done
  report_kv efi-backups "$n"
}

report_section_packages() {
  report_kv section packages
  if ! command -v pacman >/dev/null 2>&1; then
    report_kv packages pacman-not-available
    return
  fi
  local p ver
  for p in linux linux-headers acpi_call-dkms dkms t1bridge t1bridge-dkms \
           libfprint-t1bridge fprintd-t1bridge libfprint fprintd; do
    ver=$(pacman -Q "$p" 2>/dev/null | awk '{print $2}')
    report_kv "pkg.$p" "${ver:-not-installed}"
  done
  if command -v t1bridge >/dev/null 2>&1; then
    report_kv t1bridge-bin yes
  else
    report_kv t1bridge-bin no
  fi
}

report_section_t1bridge() {
  report_kv section t1bridge
  if ! command -v t1bridge >/dev/null 2>&1; then
    report_kv t1bridge-status not-installed
    return
  fi
  if ! report_is_root; then
    report_kv t1bridge-status needs-root
    return
  fi
  local line
  # `t1bridge status` is documented read-only; the first 30 lines, prefixed so they parse
  while IFS= read -r line; do
    report_kv t1bridge-status "$line"
  done < <(t1bridge status 2>&1 | head -n 30)
}

# diagnostic lines from the redacted log directory
report_diag_from_logs() {
  local logdir="${T1R_LOG:-/var/log/t1-revive}" since="${1:-}"
  if [ ! -d "$logdir" ]; then
    report_kv diag-log absent
    return
  fi
  if [ ! -r "$logdir" ] || [ ! -x "$logdir" ]; then
    report_kv diag-log needs-root
    return
  fi
  local -a files=()
  if [ -n "$since" ]; then
    mapfile -t files < <(find "$logdir" -maxdepth 1 -type f -name '*.log' -mmin "-$since" 2>/dev/null | sort)
  else
    mapfile -t files < <(find "$logdir" -maxdepth 1 -type f -name '*.log' 2>/dev/null | sort)
  fi
  if [ "${#files[@]}" -eq 0 ]; then
    report_kv diag-log none
    return
  fi
  local out
  out=$(grep -h '^t1-revive-diagnostic v=1 ' -- "${files[@]}" 2>/dev/null | tail -n 200)
  report_kv diag-log "$(printf '%s\n' "$out" | grep -c '^t1-revive-diagnostic ')"
  [ -n "$out" ] && printf '%s\n' "$out"
}

# diagnostic lines from the journal (logger -t t1-revive)
report_diag_from_journal() {
  local since="${1:-}" out
  if ! command -v journalctl >/dev/null 2>&1; then
    report_kv diag-journal unavailable
    return
  fi
  if [ -n "$since" ]; then
    out=$(journalctl -t t1-revive -o cat --no-pager --since "-${since}min" 2>/dev/null \
          | grep '^t1-revive-diagnostic v=1 ' | grep -v ' component=test ' | tail -n 200)
  else
    out=$(journalctl -t t1-revive -o cat --no-pager 2>/dev/null \
          | grep '^t1-revive-diagnostic v=1 ' | grep -v ' component=test ' | tail -n 200)
  fi
  if [ -z "$out" ]; then
    if report_is_root; then report_kv diag-journal 0; else report_kv diag-journal 0-or-needs-root; fi
    return
  fi
  report_kv diag-journal "$(printf '%s\n' "$out" | grep -c '^t1-revive-diagnostic ')"
  printf '%s\n' "$out"
}

report_section_diag() {
  local since="${1:-}"
  report_kv section diagnostics
  report_kv diag-since "${since:-all}"
  report_diag_from_logs "$since"
  report_diag_from_journal "$since"
}

# the full body, unredacted, in the fixed order
report_body() {
  local since="${1:-}"
  report_section_tool
  report_section_system
  report_section_model
  report_section_t1
  report_section_esp
  report_section_reset
  report_section_state
  report_section_packages
  report_section_t1bridge
  report_section_diag "$since"
  report_kv section end
}

# --- command --------------------------------------------------------------------------

cmd_report() {
  local out='' since=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --out)   [ $# -ge 2 ] || { report_usage; return 2; }; out=$2; shift ;;
      --out=*) out=${1#--out=} ;;
      --since) [ $# -ge 2 ] || { report_usage; return 2; }; since=$2; shift ;;
      --since=*) since=${1#--since=} ;;
      -h|--help) report_usage; return 0 ;;
      *) report_usage; return 2 ;;
    esac
    shift
  done
  if [ -n "$since" ] && ! [[ "$since" =~ ^[0-9]+$ ]]; then
    report_usage; return 2
  fi
  if ! report_have redact; then
    printf 'STOPPED: redact filter unavailable; refusing to print an unredacted report\n' >&2
    return 1
  fi
  # discover.sh may not be loaded by every dispatcher path; load it if we can
  if ! report_have esp_candidates && [ -n "${T1R_ROOT:-}" ] && [ -r "$T1R_ROOT/lib/discover.sh" ]; then
    # shellcheck source=/dev/null
    . "$T1R_ROOT/lib/discover.sh"
  fi

  local body sum
  body=$(report_body "$since" 2>/dev/null | redact)
  sum=$(printf '%s\n' "$body" | sha256sum | awk '{print $1}')

  if [ -n "$out" ]; then
    { printf '%s\n' "$body"; printf 'report-sha256: %s\n' "$sum"; } >"$out" || {
      printf 'STOPPED: cannot write %s\n' "$out" >&2; return 1; }
    printf 'report written to %s (%s lines)\n' "$out" "$(wc -l <"$out")" >&2
  else
    printf '%s\n' "$body"
    printf 'report-sha256: %s\n' "$sum"
  fi
  if ! report_is_root; then
    printf '\nnote: run with sudo for the complete bundle (sections marked needs-root)\n' >&2
  fi
  return 0
}
