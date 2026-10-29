#!/bin/sh
# Render the post to a self-contained HTML file.
#
#   ./render.sh
#   xdg-open preview.html
#
# Requires pandoc >= 3.0 (for --embed-resources).
set -eu

cd "$(dirname "$0")"

pandoc \
	--from=gfm \
	--to=html5 \
	--standalone \
	--embed-resources \
	--css=../../assets/blog.css \
	--metadata pagetitle="The panic stack" \
	--output=preview.html \
	index.md

printf 'Wrote %s\n' "$PWD/preview.html"
