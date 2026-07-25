#!/usr/bin/env bash
# =============================================================================
# Regenerate the documentation diagrams
# =============================================================================
# Sources are the .d2 files next to this script; the .svg files are committed so
# the docs render on GitHub without a build step. Re-run this after editing any
# .d2 and commit both.
#
# Requires d2: go install oss.terrastruct.com/d2@latest
#   (get.d2lang.com may be blocked by egress policy; proxy.golang.org usually is not)
#
# Usage: ./docs/diagrams/render.sh
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v d2 >/dev/null || {
  echo "d2 not found. Install with: go install oss.terrastruct.com/d2@latest" >&2
  exit 1
}

# --sketch is the hand-drawn look; --dark-theme keeps the diagrams legible for
# readers browsing GitHub in dark mode.
for src in "${HERE}"/*.d2; do
  out="${src%.d2}.svg"
  d2 --sketch --theme 0 --dark-theme 200 --pad 40 "${src}" "${out}"
done

echo
ls -l "${HERE}"/*.svg | awk '{print "    " $NF, "(" $5 " bytes)"}'

cat <<'EOF'

Check the result visually before committing — a markdown note laid out wider
than the diagram itself gets its right-hand side cut off, and nothing in the
toolchain reports it. Keep each paragraph short; blank lines separate
paragraphs, single newlines are joined into one long line.

To view: open the .svg in a browser, or
  chromium --headless --screenshot=/tmp/d.png --window-size=W,H file://$PWD/<name>.svg
EOF

