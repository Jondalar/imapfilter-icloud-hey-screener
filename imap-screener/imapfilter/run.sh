#!/bin/sh
SLEEP=5   # Intervall in Sekunden (z.B. 60, 300, 600, 1800)

while true; do
  echo "--- $(date '+%Y-%m-%d %H:%M:%S') START ---"
  imapfilter -c /config/config.lua || true
  echo "--- $(date '+%Y-%m-%d %H:%M:%S') END ---"
  sleep "$SLEEP"
done