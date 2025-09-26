#!/bin/sh
set -eu

LOG_PATH="/logs/app.log"
mkdir -p /logs

i=0
sessions=0

# Emit “Created/Removed game session …” lines exactly like your sample
while :; do
  i=$((i+1))
  # flip a coin: create or remove (don’t go below 0)
  if [ $((RANDOM%2)) -eq 0 ]; then
    sessions=$((sessions+1))
    echo "Created game session $i. Total sessions: $sessions" >> "$LOG_PATH"
  else
    if [ "$sessions" -gt 0 ]; then
      echo "Removed game session $i. Total sessions: $sessions" >> "$LOG_PATH"
      sessions=$((sessions-1))
    else
      sessions=1
      echo "Created game session $i. Total sessions: $sessions" >> "$LOG_PATH"
    fi
  fi
  sleep 1
done
