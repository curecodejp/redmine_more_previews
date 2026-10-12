#!/usr/bin/env bash
# run-watched.sh SECONDS COMMAND...
#
# Runs COMMAND in a session of its own and, if it is still running after
# SECONDS, shows what the processes of that session are doing before stopping
# them all: the process tree with groups and states, the kernel stack of each,
# and the Ruby backtraces of their threads (the handler of /tmp/rmp-debug.rb,
# on WINCH). A converter's child runs in a process group of its own, which a
# signal to the test's group misses, but stays in the session: left running, it
# would keep the step's output open after the test process is gone.
#
# With RMP_MEMORY_MAX set (f.i. 4G), COMMAND runs in a systemd scope with that
# memory and no swap: a process taking more is killed by the OOM killer instead
# of the runner swapping until nothing, the watch included, gets to run. sudo
# drops RUBYOPT, so it is passed on.
#
# The output goes to a file, shown once COMMAND is done with its lines cut to
# 2000 characters: a line of megabytes in the step's output stopped the job's
# log, and with it the step, for good.
limit=$1; shift
log=$(mktemp "${RUNNER_TEMP:-/tmp}/run-watched.XXXXXX")
show() {
  [ -n "$1" ] && echo "$1"
  cut -c1-2000 "$log"
  echo "(longest line: $(wc -L < "$log") characters)"
}
if [ -n "$RMP_MEMORY_MAX" ]; then
  setsid sudo -n --preserve-env systemd-run --quiet --scope \
    -p MemoryMax="$RMP_MEMORY_MAX" -p MemorySwapMax=0 \
    --uid="$(id -u)" --gid="$(id -g)" env PATH="$PATH" RUBYOPT="$RUBYOPT" "$@" > "$log" 2>&1 &
else
  setsid "$@" > "$log" 2>&1 &
fi
sid=$!
finished() {
  [ ! -d "/proc/$sid" ] || grep -q '^State:.*Z' "/proc/$sid/status" 2>/dev/null
}
# checked once more after the last second, for a command ending in it
for _ in $(seq "$limit"); do
  finished && break
  sleep 1
done
if finished; then
  wait "$sid"
  status=$?
  pkill -KILL -s "$sid" 2>/dev/null
  [ "$status" -eq 137 ] && error="::error::killed (out of memory?): $*"
  show "$error"
  exit $status
fi
{
  echo "--- still running after ${limit}s"
  free -m
  ps -s "$sid" -o pid,ppid,pgid,stat,rss,wchan:32,etime,args --forest
  for p in $(pgrep -s "$sid"); do
    echo "--- kernel stack of $p"
    sudo -n cat "/proc/$p/stack" 2>/dev/null
    for t in /proc/$p/task/*; do
      echo "  task ${t##*/}: $(cut -d' ' -f3 "$t/stat" 2>/dev/null) $(cat "$t/wchan" 2>/dev/null)"
    done
  done
} >> "$log" 2>&1
pkill -WINCH -s "$sid"
sleep 5
sudo -n pkill -KILL -s "$sid" || pkill -KILL -s "$sid"
wait "$sid"
show "::error::still running after ${limit}s: $*"
exit 124
