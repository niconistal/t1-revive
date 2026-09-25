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
  mkdir -p "$T1R_TMP/stubs"
  : >"$T1R_TMP/calls"
  export PATH="$T1R_TMP/stubs:$PATH"
  stub omarchy-audio-output-sink 'echo synthetic_sink'
  stub pactl 'if [[ $1 == list ]]; then
    printf "Sink #1\n\tName: other_sink\n\tMute: yes\n\tVolume: front-left: 0 /   7%% / -inf dB\n"
    printf "Sink #2\n\tName: synthetic_sink\n\tMute: %s\n" "${MUTE:-no}"
    printf "\tVolume: front-left: 32768 /  %s%% / -18.06 dB\n" "${VOL:-50}"
  fi'
  stub busctl 'echo "as 2 \"org.freedesktop.DBus\" \"${BUS_NAME:-:1.1}\""'
  # No inherited signature, so the suite behaves the same on a machine without Hyprland.
  unset HYPRLAND_INSTANCE_SIGNATURE
  # DPMS is a space-separated list of per-monitor states; unset means Hyprland is not running.
  # STALE_SIG models what a running renderer sees after Hyprland restarts: the socket behind the
  # inherited signature is gone, and only an explicitly named instance still answers.
  stub hyprctl 'if [[ -n ${STALE_SIG:-} && ${1:-} != -i ]]; then exit 0; fi
  if [[ -n ${DPMS:-} ]]; then for d in $DPMS; do printf "Monitor X:\n\tdpmsStatus: %s\n" "$d"; done; else exit 1; fi'
  stub omarchy-osd ':'
  stub omarchy-shell ':'
  stub notify-send ':'
  stub omarchy-audio-output-volume ':'
  # Unset DISPLAY_PCT means Omarchy cannot resolve the focused display, so the default is the
  # sysfs fallback and a test that needs the resolver has to say so.
  stub omarchy-brightness-display 'if [[ -n ${DISPLAY_PCT:-} ]]; then echo "$DISPLAY_PCT"; else exit 1; fi'
}

# fake_level REL CUR MAX: a synthetic brightness node at $T1R_TMP/sys/REL, and T1R_SYSFS
# pointed at that root. Obviously synthetic device names.
fake_level() {
  mkdir -p "$T1R_TMP/sys/$1"
  printf '%s\n' "$2" >"$T1R_TMP/sys/$1/brightness"
  printf '%s\n' "$3" >"$T1R_TMP/sys/$1/max_brightness"
  export T1R_SYSFS=$T1R_TMP/sys
}

# wait_call LINE: the OSD and the notification are detached on purpose, so the stub may write
# its line after the provider has already exited. Poll for it rather than racing it.
wait_call() {
  local i
  for ((i = 0; i < 100; i++)); do
    grep -qx "$1" "$T1R_TMP/calls" && return 0
    sleep 0.02
  done
  printf 'no such call: %s\n--- calls ---\n%s\n' "$1" "$(cat "$T1R_TMP/calls")" >&2
  return 1
}

provider() { run bash "$T1R_REPO/$PROVIDER" "$@"; }

@test "status: audio, notification and levels without a player or Hyprland" {
  provider v1 status
  assert_status 0
  [[ $output == "T1BRIDGE-DESKTOP 1 13 50 0" ]]
}

@test "status: media and display bits, muted, volume clamped to 100" {
  VOL=150 MUTE=yes DPMS=1 BUS_NAME=org.mpris.MediaPlayer2.synthetic provider v1 status
  assert_status 0
  [[ $output == "T1BRIDGE-DESKTOP 1 31 100 1 1" ]]
}

@test "status: displays off reports display 0" {
  DPMS=0 provider v1 status
  [[ $output == "T1BRIDGE-DESKTOP 1 29 50 0 0" ]]
}

@test "status: display is on while any monitor is on, and reads the selected sink only" {
  DPMS="0 1" MUTE=yes VOL=30 provider v1 status
  [[ $output == "T1BRIDGE-DESKTOP 1 29 30 1 1" ]]
}

@test "status: display survives a stale Hyprland instance signature" {
  STALE_SIG=1 HYPRLAND_INSTANCE_SIGNATURE=synthetic_stale_signature DPMS=1 provider v1 status
  assert_status 0
  assert_eq "T1BRIDGE-DESKTOP 1 29 50 0 1" "$output"
  grep -qx 'hyprctl -i 0 monitors' "$T1R_TMP/calls"
}

@test "status: display power can be switched off for a renderer that predates it" {
  T1BRIDGE_OMARCHY_DISPLAY_POWER=0 DPMS=1 provider v1 status
  assert_status 0
  assert_eq "T1BRIDGE-DESKTOP 1 13 50 0" "$output"
  run grep -c hyprctl "$T1R_TMP/calls"
  assert_eq 0 "$output" "the renderer was told nothing about display power"
}

@test "status: no sink withdraws audio with dash fields" {
  stub omarchy-audio-output-sink ':'
  provider v1 status
  [[ $output == "T1BRIDGE-DESKTOP 1 12 - -" ]]
}

@test "status record fits the 128-byte stdout limit" {
  VOL=100 MUTE=yes DPMS=1 BUS_NAME=org.mpris.MediaPlayer2.x provider v1 status
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

@test "media actions exit zero" {
  local op
  for op in media-previous media-play-pause media-next; do
    provider v1 "$op"
    assert_status 0
  done
  grep -qx 'omarchy-shell media playPause' "$T1R_TMP/calls"
}

@test "toggle-mute goes through Omarchy's helper, so the mute debounce is one window" {
  provider v1 toggle-mute
  assert_status 0
  grep -qx 'omarchy-audio-output-volume mute-toggle' "$T1R_TMP/calls"
  run grep -c 'set-sink-mute' "$T1R_TMP/calls"
  [[ $output == 0 ]]
}

@test "show-display-brightness reports the focused display, not the first backlight" {
  fake_level class/backlight/synthetic0 9 100     # a dimmed internal panel
  DISPLAY_PCT=76 provider v1 show-display-brightness
  assert_status 0
  wait_call 'omarchy-osd -i brightness -p 76'
  refute_contains "$(cat "$T1R_TMP/calls")" 'brightness -p 9'
}

@test "show-display-brightness falls back to a sysfs backlight when Omarchy cannot answer" {
  fake_level class/backlight/synthetic0 50 200
  provider v1 show-display-brightness
  assert_status 0
  wait_call 'omarchy-osd -i brightness -p 25'
}

@test "show-display-brightness skips a backlight with a zero or unreadable maximum" {
  fake_level class/backlight/synthetic0 0 0
  fake_level class/backlight/synthetic1 40 80
  provider v1 show-display-brightness
  assert_status 0
  wait_call 'omarchy-osd -i brightness -p 50'
}

@test "show-display-brightness with no display and no backlight exits 1 and says nothing" {
  provider v1 show-display-brightness
  assert_status 1
  assert_eq "" "$output" "an unmatched sysfs glob must not reach stderr"
}

@test "a non-numeric sysfs level is rejected rather than evaluated" {
  fake_level class/backlight/synthetic0 '$(exit 42)' 100
  provider v1 show-display-brightness
  assert_status 1
  assert_eq "" "$output" "the value must never be arithmetic"
}

@test "show-keyboard-backlight reads the LED under the sysfs root" {
  fake_level 'class/leds/synthetic::kbd_backlight' 3 4
  provider v1 show-keyboard-backlight
  assert_status 0
  wait_call 'omarchy-osd -i keyboard -p 75'
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
