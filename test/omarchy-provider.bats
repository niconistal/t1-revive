#!/usr/bin/env bats
# contrib/omarchy/t1bridge-omarchy-provider.sh against stubbed pactl, busctl, hyprctl and
# Omarchy helpers. Checks the t1bridge desktop provider v1 status record and action exits.

load test_helper/common

PROVIDER=contrib/omarchy/t1bridge-omarchy-provider.sh

# stub NAME BODY: a fake command on PATH that records its arguments and runs BODY.
stub() {
  printf '#!/bin/bash\necho "%s $*" >>"%s/calls"\n%s\n' "$1" "$T1R_TMP" "$2" >"$T1R_TMP/stubs/$1"
  chmod +x "$T1R_TMP/stubs/$1"
}

setup() {
  t1r_env
  command -v jq >/dev/null || skip "jq not installed"
  mkdir -p "$T1R_TMP/stubs"
  : >"$T1R_TMP/calls"
  export PATH="$T1R_TMP/stubs:$PATH"
  stub omarchy-audio-output-sink 'echo synthetic_sink'
  stub pactl 'case $1 in
    get-sink-volume) echo "Volume: front-left: 32768 /  ${VOL:-50}% / -18.06 dB" ;;
    get-sink-mute) echo "Mute: ${MUTE:-no}" ;;
  esac'
  stub busctl 'echo "${BUS_NAMES:-org.freedesktop.DBus 1 dbus-daemon}"'
  stub hyprctl 'if [[ -n ${DPMS:-} ]]; then echo "[{\"dpmsStatus\": $DPMS}]"; else exit 1; fi'
  stub omarchy-osd ':'
  stub omarchy-shell ':'
  stub notify-send ':'
}

provider() { run bash "$T1R_REPO/$PROVIDER" "$@"; }

@test "status: audio, notification and levels without a player or Hyprland" {
  provider v1 status
  assert_status 0
  [[ $output == "T1BRIDGE-DESKTOP 1 13 50 0" ]]
}

@test "status: media and display bits, muted, volume clamped to 100" {
  VOL=150 MUTE=yes DPMS=true BUS_NAMES="org.mpris.MediaPlayer2.synthetic 1 player" provider v1 status
  assert_status 0
  [[ $output == "T1BRIDGE-DESKTOP 1 31 100 1 1" ]]
}

@test "status: displays off reports display 0" {
  DPMS=false provider v1 status
  [[ $output == "T1BRIDGE-DESKTOP 1 29 50 0 0" ]]
}

@test "status: no sink withdraws audio with dash fields" {
  stub omarchy-audio-output-sink ':'
  provider v1 status
  [[ $output == "T1BRIDGE-DESKTOP 1 12 - -" ]]
}

@test "status record fits the 128-byte stdout limit" {
  VOL=100 MUTE=yes DPMS=true BUS_NAMES="org.mpris.MediaPlayer2.x" provider v1 status
  ((${#output} <= 128))
}

@test "set-volume unmutes and sets the percentage" {
  provider v1 set-volume 42
  assert_status 0
  grep -qx 'pactl set-sink-mute synthetic_sink 0' "$T1R_TMP/calls"
  grep -qx 'pactl set-sink-volume synthetic_sink 42%' "$T1R_TMP/calls"
}

@test "set-volume rejects out-of-range and non-numeric levels" {
  provider v1 set-volume 101
  assert_status 2
  provider v1 set-volume abc
  assert_status 2
  run grep -c set-sink-volume "$T1R_TMP/calls"
  [[ $output == 0 ]]
}

@test "toggle-mute and media actions exit zero" {
  local op
  for op in toggle-mute media-previous media-play-pause media-next; do
    provider v1 "$op"
    assert_status 0
  done
  grep -qx 'pactl set-sink-mute synthetic_sink toggle' "$T1R_TMP/calls"
  grep -qx 'omarchy-shell media playPause' "$T1R_TMP/calls"
}

@test "unknown version, operation or fallback reason exits nonzero" {
  provider v2 status
  assert_status 2
  provider v1 run-anything
  assert_status 2
  provider v1 notify-renderer-fallback something-else
  assert_status 2
  provider v1 notify-renderer-fallback selection-exited
  assert_status 0
}

@test "sourcing the provider has no side effects" {
  run bash -c 'source "$1" && echo __ok__' _ "$T1R_REPO/$PROVIDER"
  [[ $output == "__ok__" ]]
}
