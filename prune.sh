#!/bin/sh
# Prune the official Hermes image down to what a Railway dashboard + gateway
# deployment actually executes. Runs inside a build stage; the result is
# flattened by `COPY --from` into a fresh stage (see Dockerfile).
#
#   $1 = KEEP_BROWSER (1 = keep Playwright/Chromium, 0 = remove)
#
# Every removal below was verified against the extracted v0.21.0 rootfs:
# the dashboard serves the prebuilt SPA, `hermes --version` works, and
# gateway.run / hermes_cli.web_server / tools.web_tools / agent.agent_init /
# tui_gateway all still import.
set -eu

KEEP_BROWSER="${1:-0}"

before=$(du -sm / 2>/dev/null | cut -f1)

rm_group() {
    label=$1
    shift
    for p in "$@"; do rm -rf "$p"; done
    echo "  pruned: ${label}"
}

# --- Build caches ----------------------------------------------------------
rm_group "uv wheel cache"        /root/.cache/uv                       # 327M
rm_group "npm/_npx cache"        /root/.npm                            #  18M
rm_group "node compile cache"    /tmp/node-compile-cache               #   6M

# --- Node build-time trees -------------------------------------------------
# The image PREBUILDS both frontends: hermes_cli/web_dist/ (3.2M, the
# dashboard SPA) and ui-tui/dist/entry.js (3.6M, the chat TUI). Neither
# needs node_modules at runtime — entry.js is a self-contained esbuild
# bundle whose only bare requires are node: builtins (verified). Node
# itself (142M) and npm STAY: the dashboard's Chat tab spawns
# `node --expose-gc ui-tui/dist/entry.js` as a PTY child.
rm_group "root node_modules"     /opt/hermes/node_modules              # 313M

# Removing web/ entirely also disarms _build_web_ui(): it returns early when
# web/package.json is absent, so a stray unset HERMES_WEB_DIST degrades to
# "serve the prebuilt dist" instead of "npm ci at boot".
rm_group "web/ SPA source"       /opt/hermes/web                       #  12M

# ui-tui/package.json MUST survive: it carries `"type": "module"`, and
# dist/entry.js is ESM (`import { createRequire } ...`). Delete it and
# node parses the bundle as CJS and dies on the first import statement.
rm_group "ui-tui TS source" \
    /opt/hermes/ui-tui/src \
    /opt/hermes/ui-tui/packages \
    /opt/hermes/ui-tui/node_modules \
    /opt/hermes/ui-tui/scripts \
    /opt/hermes/ui-tui/tsconfig.json \
    /opt/hermes/ui-tui/tsconfig.build.json \
    /opt/hermes/ui-tui/vitest.config.ts \
    /opt/hermes/ui-tui/eslint.config.mjs                               #   5M

# macOS-only iMessage bridge; cannot run on Linux at all.
rm_group "photon iMessage sidecar" \
    /opt/hermes/plugins/platforms/photon/sidecar/node_modules          #  83M

# --- Build-time toolchain -------------------------------------------------
# Compiling native Python extensions happens during `uv sync` in the base
# build, never at runtime (HERMES_DISABLE_LAZY_INSTALLS=1 + a sealed venv).
rm_group "C/C++ toolchain" \
    /usr/libexec/gcc /usr/lib/gcc /usr/include/c++ \
    /usr/bin/x86_64-linux-gnu-lto-dump-14                              # 169M
rm_group "cmake/ctest/cpack" \
    /usr/bin/cmake /usr/bin/ctest /usr/bin/cpack /usr/share/cmake-3.31 #  48M
rm_group "static libs" \
    /usr/lib/python3.13/config-3.13-x86_64-linux-gnu \
    /usr/lib/x86_64-linux-gnu/libc.a                                   #  30M
rm_group "docker CLI"            /usr/bin/docker                       #  29M

# --- OS noise -------------------------------------------------------------
rm_group "apt lists"             /var/lib/apt/lists                    #  21M
rm_group "docs/man/info"         /usr/share/doc /usr/share/man /usr/share/info
rm_group "locales"               /usr/share/locale                     #  71M
rm_group "dev/CI leftovers" \
    /opt/hermes/evals /opt/hermes/tests-js /opt/hermes/contributors \
    /opt/hermes/mcp-research-data /opt/hermes/nix /opt/hermes/flake.nix \
    /opt/hermes/flake.lock /opt/hermes/eslint.config.shared.mjs

# --- Browser automation (opt-in) -----------------------------------------
# Playwright's Chromium + its font/GL/X11 dependencies. Removing this
# disables the `browser` tool and Playwright-backed web extraction; the
# dashboard, chat, gateway, cron and every HTTP-based tool are unaffected.
if [ "$KEEP_BROWSER" = "1" ]; then
    echo "  KEPT: browser automation (+556M)"
else
    rm_group "playwright chromium+ffmpeg" /opt/hermes/.playwright      # 266M
    rm_group "fonts"                      /usr/share/fonts             #  93M
    # libgallium is the only consumer of libLLVM/libz3 in the image
    # (verified with a recursive DT_NEEDED grep), so all three go together.
    rm_group "mesa/LLVM GPU stack" \
        /usr/lib/x86_64-linux-gnu/libLLVM.so.19.1 \
        /usr/lib/x86_64-linux-gnu/libgallium-25.0.7-2+deb13u1.so \
        /usr/lib/x86_64-linux-gnu/libz3.so.4 \
        /usr/lib/x86_64-linux-gnu/dri                                  # 191M
    rm_group "Xvfb/X11 utils" \
        /usr/bin/Xvfb /usr/bin/xkbcomp /usr/bin/xkbprint \
        /usr/bin/xkbevd /usr/share/X11                                 #   7M
fi

# PYTHONDONTWRITEBYTECODE=1 is set in the image, so these are never
# regenerated; the interpreter just compiles on import each boot.
find / -xdev -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true

after=$(du -sm / 2>/dev/null | cut -f1)
echo "prune: ${before}M -> ${after}M (browser=${KEEP_BROWSER})"

# --- Verify the pruned tree still works ----------------------------------
# Fail the BUILD, not the deploy, if a removal broke something.
#
# HERMES_HOME is redirected to a throwaway dir on purpose. Importing
# hermes_cli.main bootstraps $HERMES_HOME (SOUL.md, sessions/, logs/,
# memories/, hooks/, image_cache/ ...), and this stage runs as ROOT — so
# pointing it at /opt/data would bake root-owned state into the image.
# stage2-hook.sh only runs its targeted chown when /opt/data's own uid is
# wrong, which it wouldn't be, so those dirs would stay root-owned and the
# uid-10000 dashboard would EACCES on any deploy without a mounted volume.
HERMES_HOME=/tmp/prune-verify-home \
HERMES_WRITE_SAFE_ROOT=/tmp/prune-verify-home \
/opt/hermes/.venv/bin/python3 - <<'PY'
import importlib, pathlib, sys
for m in ("hermes_cli.main", "hermes_cli.web_server", "gateway.run",
          "tools.web_tools", "agent.agent_init", "tui_gateway"):
    importlib.import_module(m)
must = [
    "/opt/hermes/hermes_cli/web_dist/index.html",   # dashboard SPA
    "/opt/hermes/ui-tui/dist/entry.js",             # chat TUI bundle
    "/opt/hermes/ui-tui/package.json",              # ESM type marker
    "/opt/hermes/docker/entrypoint-dispatch.sh",
    "/opt/hermes/docker/main-wrapper.sh",
    "/etc/s6-overlay/s6-rc.d/dashboard/run",
]
missing = [p for p in must if not pathlib.Path(p).exists()]
if missing:
    sys.exit("prune broke the image, missing: " + ", ".join(missing))
print("prune verify: imports OK, runtime assets present")
PY
rm -rf /tmp/prune-verify-home

# Guard the guard: assert the verify left no root-owned state on the data
# volume mountpoint. Anything beyond the three /etc/skel dotfiles the base
# image ships means something bootstrapped $HERMES_HOME as root.
stray=$(find /opt/data -mindepth 1 ! -name '.bashrc' ! -name '.profile' \
        ! -name '.bash_logout' -print 2>/dev/null | head -5)
if [ -n "$stray" ]; then
    echo "ERROR: root-owned state baked into /opt/data:" >&2
    echo "$stray" >&2
    exit 1
fi
echo "prune verify: /opt/data clean"
