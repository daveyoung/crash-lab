#!/bin/sh
# Build the static site into docs/ for GitHub Pages.
#
#   ./build.sh
#
# Requires pandoc >= 3.0 (for --embed-resources).
set -eu

cd "$(dirname "$0")"
ROOT=$(pwd)
OUT=$ROOT/docs
CSS=$ROOT/assets/blog.css

rm -rf "$OUT"
mkdir -p "$OUT"

render() {
	in=$1
	out=$2
	title=$3
	dir=$(dirname "$in")
	base=$(basename "$in")

	mkdir -p "$(dirname "$out")"
	(
		cd "$dir"
		pandoc \
			--from=gfm \
			--to=html5 \
			--standalone \
			--embed-resources \
			--css="$CSS" \
			--metadata "pagetitle=$title" \
			--output="$out" \
			"$base"
	)
}

# Landing page: fill the <!--POSTS--> marker from site/plan.tsv. A post is
# "finished" when its directory exists; everything else is listed as coming.
POSTS_MD=$ROOT/site/.posts.md
INDEX_MD=$ROOT/site/.index.build.md
trap 'rm -f "$POSTS_MD" "$INDEX_MD"' EXIT

: > "$POSTS_MD"
part=
first=1
while IFS='	' read -r p n slug title; do
	[ "$n" = "number" ] && continue
	[ -n "${n:-}" ] || continue
	if [ "$p" != "$part" ]; then
		[ $first -eq 0 ] && printf '\n' >> "$POSTS_MD"
		printf '### %s\n\n' "$p" >> "$POSTS_MD"
		part=$p
		first=0
	fi
	if [ -f "$ROOT/posts/$n-$slug/index.md" ]; then
		printf -- '- **%s.** [%s](posts/%s-%s/)\n' "$n" "$title" "$n" "$slug" >> "$POSTS_MD"
	else
		printf -- '- **%s.** *%s* — coming\n' "$n" "$title" >> "$POSTS_MD"
	fi
done < "$ROOT/site/plan.tsv"

awk -v listfile="$POSTS_MD" '
	/<!--POSTS-->/ { while ((getline line < listfile) > 0) print line; next }
	{ print }
' "$ROOT/site/index.md" > "$INDEX_MD"

render "$INDEX_MD" "$OUT/index.html" "Crash Lab"

# Posts, each with its answers.
for dir in posts/*/; do
	slug=$(basename "$dir")
	title=$(sed -n '1s/^# //p' "$dir/index.md")
	render "$dir/index.md" "$OUT/posts/$slug/index.html" "$title"
	render "$dir/answers.md" "$OUT/posts/$slug/answers.html" "$title — answers"
done

# The module README is linked from Post 2 as ../../crashlab/.
render crashlab/README.md "$OUT/crashlab/index.html" "crashlab"

# Markdown links to answers become HTML links on the site.
find "$OUT" -name '*.html' -exec sed -i 's|href="answers\.md"|href="answers.html"|g' {} +

# Do not let GitHub Pages run Jekyll over the output.
touch "$OUT/.nojekyll"

printf 'Wrote %s\n' "$OUT"
