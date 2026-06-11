#!/bin/sh
set -eu

LOG_DIR="${LOG_DIR:-/var/log/beamwatch}"
mkdir -p "$LOG_DIR"

elixir \
  -r ./lib/beamwatch/log_feed/entry.ex \
  -r ./lib/beamwatch/log_feed/fixtures.ex \
  -r ./lib/beamwatch/log_feed/interleaver.ex \
  -r ./lib/beamwatch/log_feed/profiles.ex \
  -r ./lib/beamwatch/log_feed/runner.ex \
  -r ./lib/beamwatch/log_feed/cli.ex \
  -e "BeamWatch.LogFeed.CLI.main([\"--profile\", \"validation\", \"--target\", System.get_env(\"LOG_DIR\", \"/var/log/beamwatch\"), \"--speed\", \"1\", \"--loop\"])" &

while true; do
  logrotate -f /etc/logrotate.d/beamwatch || true
  sleep 15
done
