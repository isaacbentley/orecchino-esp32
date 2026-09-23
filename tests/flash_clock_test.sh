#!/bin/bash
# The flash script's clock step (set_clock in tools/flash_t5epd.sh) against a
# fake board on a pseudo-terminal: every reply the firmware can give, a
# board that is slow to boot or never answers, a lost command, and the
# signals a user can send mid-step. No hardware involved.
set -uo pipefail
cd "$(dirname "$0")/.."
source tools/flash_t5epd.sh          # defines set_clock and returns
set +e
export T5_CLOCK_WAIT=3

TMP="$(/usr/bin/mktemp -d -t orecchino_clocktest)"
TEMPS="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo "${TMPDIR:-/tmp}")"
fails=0
ok()   { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

board_up() {   # board_up MODE -> sets BOARD (pid) and PORT
  : > "$TMP/board.out"
  python3 tests/fake_t5_board.py "$1" 30 > "$TMP/board.out" 2>/dev/null &
  BOARD=$!
  local i=0
  until [ -s "$TMP/board.out" ] || [ $i -ge 100 ]; do sleep 0.05; i=$((i + 1)); done
  PORT="$(head -n 1 "$TMP/board.out")"
}
board_down() { kill "$BOARD" 2>/dev/null; wait "$BOARD" 2>/dev/null; }
# set_clock's capture files live in the user temp dir (macOS mktemp -t ignores
# TMPDIR), where a real flash may have one open. Snapshot before each run and
# flag only files that appeared since; never delete anything there.
captures() { ls "$TEMPS"/orecchino_rtc.* 2>/dev/null | sort; }
leftovers() {  # stray readers on this pty, and capture files this run left behind
  pgrep -f "^cat $PORT\$" >/dev/null && echo "a reader is still holding $PORT"
  local new; new="$(comm -13 <(printf '%s\n' "$BEFORE") <(captures))"
  [ -n "$new" ] && echo "capture file left behind: $new"
}

check() {      # check MODE WANT_STATUS TEXT
  local mode="$1" want="$2" text="$3" out status
  board_up "$mode"
  BEFORE="$(captures)"
  out="$(set_clock "$PORT" 2>&1)"; status=$?
  local left; left="$(leftovers)"
  board_down
  if [ "$status" = "$want" ] && printf '%s' "$out" | grep -q -e "$text" && [ -z "$left" ]; then
    ok "$mode: status $status, \"$text\""
  else
    fail "$mode: status $status (want $want); output: $out; $left"
  fi
}

check ok         0 "Clock set: the board's clock chip reads [0-9]\{4\}-"
check late       0 "Clock set:"
check drop-first 0 "Clock set:"
check null       1 "clock chip did not take the time"
check old        1 "cannot report its clock"
check refuse     1 "refused .* as out of range"
check stale      1 "clock chip reads 2025-01-06T07:18:21Z, not [0-9]\{4\}-"
check silent     1 "did not answer on"

# Signals mid-step, sent to the process group the way a terminal sends
# them: the script must die of that signal (so a calling loop stops too),
# with no reader left on the port and no capture file left behind.
for sig in INT QUIT TERM HUP; do
  board_up silent
  BEFORE="$(captures)"
  set -m
  /bin/bash -c 'source tools/flash_t5epd.sh; set +e; T5_CLOCK_WAIT=30 set_clock "$0"; echo survived' "$PORT" > "$TMP/sig.out" 2>&1 &
  driver=$!
  set +m
  sleep 1.5
  kill -"$sig" -- -"$driver" 2>/dev/null
  { wait "$driver"; } 2>/dev/null; status=$?
  sleep 0.3
  left="$(leftovers)"
  board_down
  want=$((128 + $(kill -l "$sig")))
  if [ "$status" = "$want" ] && ! grep -q survived "$TMP/sig.out" && [ -z "$left" ]; then
    ok "SIG$sig mid-step: exits $status, reader stopped, capture removed"
  else
    fail "SIG$sig mid-step: status $status (want $want); $(cat "$TMP/sig.out"); $left"
  fi
  pkill -f "^cat $PORT\$" 2>/dev/null
done

rm -rf "$TMP"
if [ "$fails" -gt 0 ]; then echo "$fails FAILED"; exit 1; fi
echo "all flash clock checks passed"
