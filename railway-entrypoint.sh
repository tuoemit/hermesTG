#!/bin/sh
# Bridge Railway's dynamic PORT to Hermes' dashboard port, then delegate to
# Hermes' own entrypoint dispatcher.
set -eu

: "${PORT:=9119}"

case "$PORT" in
    ''|*[!0-9]*)
        echo "ERROR: PORT must be a numeric TCP port (got '$PORT')" >&2
        exit 2
        ;;
esac

if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "ERROR: PORT must be between 1 and 65535 (got '$PORT')" >&2
    exit 2
fi

# Railway's PORT is authoritative. Allowing a separate dashboard port causes
# Railway's health probe and Hermes to disagree about where the service lives.
export HERMES_DASHBOARD_PORT="$PORT"

# Delegate to the upstream dispatcher rather than /init directly. The
# dispatcher preserves Hermes' normal s6-overlay PID-1 path and its wrapped-
# runtime fallback path.
exec /opt/hermes/docker/entrypoint-dispatch.sh "$@"
