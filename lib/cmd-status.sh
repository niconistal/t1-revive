#!/usr/bin/env bash
# lib/cmd-status.sh - cmd_status: one screen of facts. Works as a normal user (degrades to
# "not readable" where root is needed); never mounts, never touches the T1.
#
# shellcheck shell=bash

_st() { printf '  %-14s %s\n' "$1" "$2"; }

cmd_status() {
  local model t1 cfg esp dev mp has line n out
  case "${1:-}" in -h|--help) echo "usage: t1-revive status"; return 0;; *) ;; esac
  printf 't1-revive %s\n' "$(version)"

  model=$(model_id)
  _st "model" "$model ($(model_status "$model"))"
  _st "kernel" "$(uname -r) on $(distro_id)"

  t1=$(t1_state); cfg=$(t1_config)
  case "$t1" in
    recovery) _st "T1" "recovery (05ac:1281): EmbeddedOS not loaded";;
    booted) _st "T1" "booted (05ac:8600), USB configuration ${cfg:-?}$( [[ "$cfg" = 2 ]] && printf ' (t1bridge)')";;
    *) _st "T1" "not on the USB bus";;
  esac

  n=0
  while read -r dev mp has; do
    [[ -n "$dev" ]] || continue
    n=$((n + 1))
    if [[ "$mp" = "-" ]]; then
      case "$has" in
        yes) _st "ESP" "$dev (not mounted; looked at read-only): EFI/APPLE present";;
        no) _st "ESP" "$dev (not mounted; looked at read-only): no EFI/APPLE";;
        *) if [[ "${EUID:-$(id -u)}" = 0 ]]; then _st "ESP" "$dev (not mounted; could not be looked at)"
           else _st "ESP" "$dev (not mounted; run as root to look inside it)"; fi;;
      esac
    else
      case "$has" in yes) out="EFI/APPLE present";; no) out="no EFI/APPLE";; *) out="EFI/APPLE: not readable";; esac
      [[ ! -r "$mp" ]] && out="EFI/APPLE: not readable as this user"
      _st "ESP" "$dev at $mp: $out"
      if [[ -d "$mp/EFI/APPLE/EMBEDDEDOS" ]]; then
        _st "" "EMBEDDEDOS: $(dir_names "$mp/EFI/APPLE/EMBEDDEDOS")"
      elif [[ "$has" = yes ]]; then _st "" "EMBEDDEDOS folder missing"; fi
    fi
  done < <(esp_candidates)
  [[ "$n" = 0 ]] && _st "ESP" "none found"
  if [[ "$n" -gt 1 ]]; then
    if esp=$(esp_select); then _st "" "selected: ${esp%% *} ($(esp_select --why))"
    else _st "" "ambiguous: t1-revive cannot choose between them (pin one with T1R_ESP_DEV in t1-revive.conf)"; fi
  fi

  out=$(frst_method)
  if [[ -n "$out" ]]; then _st "FRST method" "found ($out)"
  elif [[ ! -r "$T1R_ACPI_TABLES/DSDT" ]]; then _st "FRST method" "unknown (ACPI tables not readable as this user)"
  else _st "FRST method" "not found"; fi

  if [[ -d "$T1R_STATE" ]]; then
    if [[ -r "$T1R_STATE" ]]; then
      if dir_nonempty "$T1R_STATE/private"; then
        _st "private state" "present ($T1R_STATE/private)"
        # step markers written by the regeneration: $T1R_STATE/private/steps/<name>.done
        out=$(find "$T1R_STATE/private/steps" -mindepth 1 -maxdepth 1 -name '*.done' -printf '%f\n' 2>/dev/null | sed 's/\.done$//' | sort | paste -sd' ')
        _st "" "steps done: ${out:-none}"
        _st "" "files: $(dir_names "$T1R_STATE/private")"
      else _st "private state" "none"; fi
      out=$(backup_latest)
      if [[ -n "$out" ]]; then _st "EFI backup" "${out##*/}"; else _st "EFI backup" "none under $T1R_STATE"; fi
    else _st "private state" "$T1R_STATE not readable as this user"; fi
  else _st "private state" "none ($T1R_STATE does not exist)"; fi

  if declare -F distro_installed >/dev/null && distro_installed t1bridge 2>/dev/null; then
    _st "t1bridge" "installed $(distro_pkg_version t1bridge)"
    if command -v t1bridge >/dev/null 2>&1; then
      out=$(timeout 5 t1bridge status 2>/dev/null | head -4)
      if [[ -n "$out" ]]; then while IFS= read -r line; do _st "" "$line"; done <<<"$out"
      else _st "" "t1bridge status: no output (needs root?)"; fi
    fi
  else _st "t1bridge" "not installed"; fi

  out=
  [[ -r "$T1R_LOG/diagnostics.log" ]] && out=$(tail -1 "$T1R_LOG/diagnostics.log" 2>/dev/null)
  # component=test lines are the bats suite's (older builds wrote them to the journal): not this machine's history
  [[ -z "$out" ]] && command -v journalctl >/dev/null 2>&1 && \
    out=$(journalctl -q -t t1-revive -o cat 2>/dev/null | grep -v ' component=test ' | tail -n 1)
  _st "last diag" "${out:-none}"
  if [[ -L "$T1R_LOG/latest.log" ]]; then _st "last log" "$(readlink "$T1R_LOG/latest.log")"; fi
  return 0
}
