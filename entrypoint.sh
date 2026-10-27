#!/bin/sh
# The deployed image is authoritative. Legacy /data/current files are ignored.
set -u
umask 077
child_pid=
shutdown() {
  if [ -n "$child_pid" ]; then
    kill -TERM "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  exit 0
}
trap shutdown TERM INT
while :; do
  /usr/local/bin/deemedia-link "$@" &
  child_pid=$!
  wait "$child_pid"
  status=$?
  child_pid=
  # Restore asks the supervisor to reload state. Always restart the image binary.
  if [ "$status" -eq 75 ]; then continue; fi
  exit "$status"
done
