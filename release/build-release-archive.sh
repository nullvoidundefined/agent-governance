#!/usr/bin/env bash
# build-release-archive.sh: packages one release tag as the downloadable
# release archive and its checksum. The archive is `git archive` of the tag
# (site/ is export-ignore, so it never ships) plus RELEASE-FILES, the list
# sync.sh reads when it runs from an extract instead of a git checkout. git
# writes the gzip itself, so one tag always yields the same bytes.
#
# Usage: release/build-release-archive.sh <vMAJOR.MINOR.PATCH> <out-dir>
set -euo pipefail
tag="${1:-}"
out_dir="${2:-}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# refuse(reason): stops without writing anything.
refuse() { echo "REFUSED: $*" >&2; exit 1; }

[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || refuse "tag '$tag' is not vMAJOR.MINOR.PATCH"
git -C "$repo_root" rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null || refuse "tag $tag does not exist"
[ -d "$out_dir" ] || refuse "output folder '$out_dir' does not exist"

name="agent-governance-$tag"
file_list=$(git -C "$repo_root" archive --format=tar "$tag" | tar -t | grep -v '/$' | LC_ALL=C sort)
archive="$out_dir/$name.tar.gz"
git -C "$repo_root" archive --format=tar.gz --prefix="$name/" \
  --add-virtual-file="$name/RELEASE-FILES:$file_list
" -o "$archive" "$tag"
(cd "$out_dir" && shasum -a 256 "$name.tar.gz" > "$name.tar.gz.sha256")
echo "$archive"
echo "$archive.sha256"
