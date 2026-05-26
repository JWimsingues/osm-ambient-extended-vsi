#!/usr/bin/env bash
# Redirect podman ms-c stdout to /var/log/osm-poc/ms-c.log for Fluent Bit tail input.
set -euo pipefail

mkdir -p /var/log/osm-poc
touch /var/log/osm-poc/ms-c.log /var/log/osm-poc/ztunnel.log
chmod 644 /var/log/osm-poc/*.log

echo "Log files ready under /var/log/osm-poc/"
echo "Restart ms-c with 04-vsi-ztunnel/scripts/run-ms-c.sh (uses --log-opt path=...)"
