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
TMP=$ROOT/site/.build.$$
trap 'rm -rf "$TMP"' EXIT

rm -rf "$OUT"
mkdir -p "$OUT" "$TMP"

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

# make_landing <template> <plan> <posts-dir> <output> <title> <coming-label>
#
# Fills the <!--POSTS--> marker from a plan file. A post is "finished" when
# <posts-dir>/NN-slug/index.md exists; the rest are rendered as coming. The
# links are always relative "posts/NN-slug/" because each landing page sits
# beside its own posts/ directory.
make_landing() {
	template=$1
	plan=$2
	checkdir=$3
	out=$4
	title=$5
	label=$6
	list=$TMP/posts.md
	page=$TMP/page.md

	: > "$list"
	part=
	first=1
	while IFS='	' read -r p n slug ptitle; do
		[ "$n" = "number" ] && continue
		[ -n "${n:-}" ] || continue
		if [ "$p" != "$part" ]; then
			[ $first -eq 0 ] && printf '\n' >> "$list"
			printf '### %s\n\n' "$p" >> "$list"
			part=$p
			first=0
		fi
		if [ -f "$ROOT/$checkdir/$n-$slug/index.md" ]; then
			printf -- '- **%s.** [%s](posts/%s-%s/)\n' "$n" "$ptitle" "$n" "$slug" >> "$list"
		else
			printf -- '- **%s.** *%s* — %s\n' "$n" "$ptitle" "$label" >> "$list"
		fi
	done < "$ROOT/$plan"

	awk -v listfile="$list" '
		/<!--POSTS-->/ { while ((getline line < listfile) > 0) print line; next }
		{ print }
	' "$ROOT/$template" > "$page"

	render "$page" "$out" "$title"
}

# English.
make_landing site/index.md site/plan.tsv posts "$OUT/index.html" "Crash Lab" "coming"
for dir in posts/*/; do
	slug=$(basename "$dir")
	title=$(sed -n '1s/^# //p' "$dir/index.md")
	render "$dir/index.md" "$OUT/posts/$slug/index.html" "$title"
	render "$dir/answers.md" "$OUT/posts/$slug/answers.html" "$title — answers"
done

# Chinese.
make_landing zh/index.md site/plan.zh.tsv zh/posts "$OUT/zh/index.html" "Crash Lab 中文" "待发布"
for dir in zh/posts/*/; do
	slug=$(basename "$dir")
	title=$(sed -n '1s/^# //p' "$dir/index.md")
	render "$dir/index.md" "$OUT/zh/posts/$slug/index.html" "$title"
	render "$dir/answers.md" "$OUT/zh/posts/$slug/answers.html" "$title — 答案"
done

# The module README is linked from Post 2 as ../../crashlab/.
render crashlab/README.md "$OUT/crashlab/index.html" "crashlab"

# Markdown links to answers become HTML links on the site.
find "$OUT" -name '*.html' -exec sed -i 's|href="answers\.md"|href="answers.html"|g' {} +

# Do not let GitHub Pages run Jekyll over the output.
touch "$OUT/.nojekyll"

printf 'Wrote %s\n' "$OUT"
