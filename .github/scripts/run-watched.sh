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
limit=$1; shift
setsid "$@" &
sid=$!
for _ in $(seq "$limit"); do
  if ! kill -0 "$sid" 2>/dev/null; then
    wait "$sid"
    status=$?
    pkill -KILL -s "$sid" 2>/dev/null
    exit $status
  fi
  sleep 1
done
echo "::error::still running after ${limit}s: $*"
ps -s "$sid" -o pid,ppid,pgid,stat,wchan:32,etime,args --forest
for p in $(pgrep -s "$sid"); do
  echo "--- kernel stack of $p"
  sudo -n cat "/proc/$p/stack" 2>/dev/null
  for t in /proc/$p/task/*; do
    echo "  task ${t##*/}: $(cut -d' ' -f3 "$t/stat" 2>/dev/null) $(cat "$t/wchan" 2>/dev/null)"
  done
done
pkill -WINCH -s "$sid"
sleep 5
pkill -KILL -s "$sid"
wait "$sid"
exit 124
