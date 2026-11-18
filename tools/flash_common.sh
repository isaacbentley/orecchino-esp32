# shellcheck shell=bash
# Shared by the tools/flash_*.sh scripts (sourced, not run).

# pick_port USAGE PATTERN... : set PORT to the one serial device matching
# the (already expanded) patterns. None, or more than one -- two boards
# plugged in at once -- is an error: flashing the wrong board is worse than
# asking which one. A port given on the command line skips this.
pick_port() {
  local usage="$1" p n=0 found=""
  shift
  for p in "$@"; do
    [ -e "$p" ] || continue
    n=$((n + 1))
    found="$found  $p"$'\n'
    PORT="$p"
  done
  if [ "$n" -eq 0 ]; then
    PORT=""
    echo "Error: No USB serial device found ($*)."
    echo "Usage: $usage"
    return 1
  fi
  if [ "$n" -gt 1 ]; then
    PORT=""
    echo "Error: $n USB serial devices found; say which one is the board:"
    printf '%s' "$found"
    echo "Usage: $usage"
    return 1
  fi
  echo "Auto-detected port: $PORT"
}

# quit_app: Orecchino.app auto-connects to serial ports and its reads
# corrupt esptool, so it must be closed first. Ask it to quit (it closes its
# ports and saves its state), and only force it if it has not gone within
# 5 s -- say, while macOS waits on an Automation permission prompt.
quit_app() {
  pgrep -x Orecchino >/dev/null 2>&1 || return 0   # quitting a closed app would launch it
  echo "Quitting Orecchino.app..."
  local osa _
  /usr/bin/osascript -e 'quit app "Orecchino"' >/dev/null 2>&1 &
  osa=$!
  for _ in $(seq 1 50); do
    pgrep -x Orecchino >/dev/null 2>&1 || break
    sleep 0.1
  done
  kill "$osa" 2>/dev/null || true
  wait "$osa" 2>/dev/null || true
  if pgrep -x Orecchino >/dev/null 2>&1; then
    echo "Orecchino.app did not quit; forcing it."
    pkill -9 -x Orecchino 2>/dev/null || true
  fi
  sleep 1   # let the ports it held go
}
