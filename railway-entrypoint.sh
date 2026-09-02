#!/bin/sh
# Bridge Railway's dynamic $PORT onto the Hermes dashboard, then delegate.
set -eu

: "${PORT:=9119}"
export HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-$PORT}"

# Delegate to the image's own entrypoint dispatcher rather than exec'ing
# /init directly.
#
# The dispatcher checks whether it is actually PID 1. s6-overlay's /init
# aborts with "can only run as pid 1" under any runtime that wraps the
# container in its own init; the dispatcher detects that and falls back to
# `stage2-hook.sh` + `main-wrapper.sh` so the CMD still runs. Hardcoding
# `exec /init ...` here throws that fallback away and turns a wrapped
# runtime into a boot loop.
#
# Env exported above is still captured: on the PID-1 path /init snapshots
# the environment into /run/s6/container_environment during stage 1, which
# is how the supervised dashboard service sees HERMES_DASHBOARD_PORT.
exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"
