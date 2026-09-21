#!/bin/bash
# contrib/omarchy/t1bridge-omarchy-provider.sh - t1bridge desktop provider v1 for Omarchy.
#
# Gives t1bridge's built-in Touch Bar renderer its volume, mute and media buttons, Omarchy's
# OSD for volume and brightness, and a dark panel while Hyprland has the displays off. The
# contract is t1bridge's docs/interfaces.md, "Desktop provider v1". Setup is in
# docs/omarchy.md. Runs as the graphical user; t1bridge's root service never calls it.
set -uo pipefail

# The user service's PATH may not include Omarchy's helpers. Append, so a caller's PATH wins.
PATH="$PATH:/usr/share/omarchy/bin"

CAP_AUDIO=1 CAP_MEDIA=2 CAP_NOTIFY=4 CAP_LEVELS=8 CAP_DISPLAY=16

# omarchy-audio-output-sink resolves through any DSP sink to the physical one, the same sink
# Omarchy's volume keys move.
out_sink() { omarchy-audio-output-sink 2>/dev/null; }

# sink_state SINK: "PERCENT MUTED" (MUTED 1 or 0) from one pactl call, the first channel's
# volume. One list is cheaper than get-sink-volume plus get-sink-mute, and status runs every
# second. C locale, because the field labels are translated.
sink_state() {
  LC_ALL=C pactl list sinks 2>/dev/null | awk -v sink="$1" '
    /^\tName: / { hit = ($2 == sink) }
    hit && /^\tMute: / { muted = ($2 == "yes") }
    hit && /^\tVolume: / {
      for (i = 2; i <= NF; i++) if ($i ~ /^[0-9]+%$/) { sub("%", "", $i); print $i, muted + 0; exit }
    }'
}

# osd ICON PERCENT: Omarchy's OSD, detached so the 500 ms deadline never waits on it.
osd() { omarchy-osd -i "$1" -p "$2" >/dev/null 2>&1 & }

show_volume() {
  local pct=0 muted=0 icon=volume-high
  read -r pct muted < <(sink_state "$1")
  pct=${pct:-0}
  if [[ $muted == 1 ]] || ((pct == 0)); then icon="volume-muted"; fi
  osd "$icon" "$pct"
}

# level_percent DIR: brightness of one sysfs backlight or LED as 0-100.
level_percent() {
  local cur max
  cur=$(<"$1/brightness") && max=$(<"$1/max_brightness") || return 1
  ((max > 0)) || return 1
  echo $((cur * 100 / max))
}

cmd_status() {
  local caps=$((CAP_NOTIFY + CAP_LEVELS)) volume=- muted=- display="" sink pct="" mute names mons
  sink=$(out_sink)
  [[ -n $sink ]] && read -r pct mute < <(sink_state "$sink")
  if [[ $pct =~ ^[0-9]+$ ]]; then
    caps=$((caps + CAP_AUDIO))
    ((pct > 100)) && pct=100   # PipeWire allows overdrive; the contract stops at 100
    volume=$pct
    muted=${mute:-0}
  fi
  # ListNames returns the bus names alone; busctl list also looks up every owner, 6x slower.
  names=$(busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus \
    ListNames 2>/dev/null)
  [[ $names == *org.mpris.MediaPlayer2.* ]] && caps=$((caps + CAP_MEDIA))
  # Advertised only while Hyprland answers; on while any monitor is on. Plain output has one
  # "dpmsStatus: N" line per monitor, so no JSON parser is needed.
  mons=$(timeout 0.2 hyprctl monitors 2>/dev/null)
  if [[ $mons == *"dpmsStatus: 1"* ]]; then
    caps=$((caps + CAP_DISPLAY)) display=" 1"
  elif [[ $mons == *"dpmsStatus: 0"* ]]; then
    caps=$((caps + CAP_DISPLAY)) display=" 0"
  fi
  echo "T1BRIDGE-DESKTOP 1 $caps $volume $muted$display"
}

main() {
  [[ ${1:-} == v1 ]] || return 2
  local op=${2:-} sink dev pct
  case $op in
    status) cmd_status ;;
    set-volume)
      [[ ${3:-} =~ ^[0-9]+$ ]] && ((10#$3 <= 100)) || return 2
      sink=$(out_sink) && [[ -n $sink ]] || return 1
      pactl set-sink-mute "$sink" 0 || return 1
      pactl set-sink-volume "$sink" "$((10#$3))%" || return 1
      show_volume "$sink"
      ;;
    toggle-mute)
      sink=$(out_sink) && [[ -n $sink ]] || return 1
      pactl set-sink-mute "$sink" toggle || return 1
      show_volume "$sink"
      ;;
    media-previous) omarchy-shell media previous >/dev/null 2>&1 ;;
    media-play-pause) omarchy-shell media playPause >/dev/null 2>&1 ;;
    media-next) omarchy-shell media next >/dev/null 2>&1 ;;
    show-display-brightness)
      for dev in /sys/class/backlight/*; do
        pct=$(level_percent "$dev") && { osd brightness "$pct"; return 0; }
      done
      return 1
      ;;
    show-keyboard-backlight)
      for dev in /sys/class/leds/*kbd_backlight*; do
        pct=$(level_percent "$dev") && { osd keyboard "$pct"; return 0; }
      done
      return 1
      ;;
    notify-renderer-fallback)
      [[ ${3:-} == selection-unavailable || ${3:-} == selection-exited ]] || return 2
      notify-send -a "Touch Bar" "Touch Bar" \
        "The selected Touch Bar renderer is not running (${3}). Using the built-in one." >/dev/null 2>&1 &
      ;;
    *) return 2 ;;
  esac
}

# Sourceable without side effects (AGENTS.md rule 7); runs only when executed.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
  exit $?
fi
