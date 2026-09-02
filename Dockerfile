# syntax=docker/dockerfile:1.7
# ============================================================================
# Railway wrapper around the official Hermes Agent image — size-optimized.
#
# WHY TWO STAGES:
#   A plain `FROM nousresearch/hermes-agent:latest` + `RUN rm -rf ...` does NOT
#   shrink the image. Docker layers are additive: a delete in a derived layer
#   records a *whiteout* entry, so the deleted bytes are still shipped in the
#   parent layer and the image gets marginally BIGGER. The only way to actually
#   drop base-image bytes is to prune inside a build stage and re-materialize
#   the tree into a fresh empty stage — which is what this file does.
#
# MEASURED on nousresearch/hermes-agent (v0.21.0, amd64):
#   base                 2839 MiB uncompressed / 986 MiB compressed
#   KEEP_BROWSER=0       1096 MiB uncompressed / 418 MiB compressed  (-61%)
#   KEEP_BROWSER=1       1652 MiB uncompressed                       (-42%)
#
# NOTE: this shrinks the DEPLOYED image, not the build. The full base still has
# to be pulled by the builder, so build time is roughly unchanged (+~30s for
# the prune and the flattening copy).
# ============================================================================

# Pin by tag, not `latest`: `latest` changes under you and a silent base bump
# is exactly what the SQLite assertion further down exists to catch.
ARG HERMES_IMAGE=nousresearch/hermes-agent:latest

# ---------------------------------------------------------------------------
# Stage 1 — take the official image and delete everything a Railway
#           dashboard + gateway deployment never executes.
# ---------------------------------------------------------------------------
FROM ${HERMES_IMAGE} AS pruned
USER root

# Fail the build if the base regresses to a SQLite with the WAL-reset
# corruption bug. Runs BEFORE the prune so a bad base fails fast.
RUN python3 -c 'import sqlite3, sys; v=sqlite3.sqlite_version_info; print("SQLite", sqlite3.sqlite_version); sys.exit("ERROR: SQLite WAL-reset fix missing; need >= 3.51.3") if v < (3,51,3) else None'

# 1 = keep Playwright/Chromium (the `browser` tool works, +556 MiB)
# 0 = drop it (default; dashboard, chat, gateway, cron all unaffected)
ARG KEEP_BROWSER=0

COPY --chmod=0755 prune.sh /prune.sh
RUN /prune.sh "${KEEP_BROWSER}" && rm -f /prune.sh

# ---------------------------------------------------------------------------
# Stage 2 — flatten the pruned tree into a fresh image.
#
# `COPY --from` preserves uid/gid, modes and symlinks, so the hermes user
# (uid 10000), the sealed root-owned /opt/hermes and the s6 tree survive.
# Verified on the extracted rootfs: no device/fifo/socket nodes and no
# setuid/setgid files exist in the base, so nothing is silently lost. Four
# hardlinked files (7.6 MiB) get duplicated — the only fidelity loss.
# ---------------------------------------------------------------------------
FROM scratch AS runtime
COPY --from=pruned / /

# --- Base-image ENV, re-declared (a `scratch` stage inherits nothing) -------
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright \
    npm_config_install_links=false \
    HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist \
    HERMES_TUI_DIR=/opt/hermes/ui-tui \
    HERMES_HOME=/opt/data \
    HERMES_WRITE_SAFE_ROOT=/opt/data:/tmp \
    HERMES_DASHBOARD_FILES_ROOT=/ \
    HERMES_DISABLE_LAZY_INSTALLS=1 \
    HERMES_LAZY_INSTALL_TARGET=/opt/data/lazy-packages \
    PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:/opt/data/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# HERMES_WEB_DIST above is load-bearing after the prune: it makes
# `hermes dashboard` serve the prebuilt SPA instead of trying to `npm ci`
# + vite-build a `web/` source tree that no longer exists.

# --- Railway-specific ENV --------------------------------------------------
ENV HERMES_DASHBOARD=1 \
    HERMES_DASHBOARD_HOST=127.0.0.1 \
    PORT=9119

WORKDIR /opt/hermes
EXPOSE 9119

# Bridge Railway's injected $PORT onto the dashboard, then hand off to the
# UPSTREAM dispatcher (not /init directly) so the non-PID-1 fallback path
# survives — see railway-entrypoint.sh.
COPY --chmod=0755 railway-entrypoint.sh /railway-entrypoint.sh
ENTRYPOINT [ "/railway-entrypoint.sh" ]
CMD [ "gateway", "run" ]
