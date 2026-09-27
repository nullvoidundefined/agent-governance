#!/usr/bin/env bash
# build-site.sh: builds site/dist from site/public and the self-hosted fonts,
# substituting the release version and checksum the download section shows.
# Refuses any value that is not exactly a release tag or a SHA-256, so a
# release name can never inject markup into the page, and refuses a build
# that leaves a placeholder behind.
#
# Usage: site/scripts/build-site.sh <vMAJOR.MINOR.PATCH> <sha256>
set -euo pipefail
version="${1:-}"
sha256="${2:-}"
site_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
dist="$site_root/dist"
font_files="space-grotesk:500 space-grotesk:700 ibm-plex-sans:400 ibm-plex-sans:600 jetbrains-mono:400 jetbrains-mono:600"

# refuse(reason): stops, leaving no dist/ behind.
refuse() { rm -rf "$dist"; echo "REFUSED: $*" >&2; exit 1; }

# copyFonts(): the six latin woff2 faces the stylesheet names, from @fontsource.
copyFonts() {
  local entry family weight source
  mkdir -p "$dist/fonts"
  for entry in $font_files; do
    family="${entry%:*}"; weight="${entry#*:}"
    source="$site_root/node_modules/@fontsource/$family/files/$family-latin-$weight-normal.woff2"
    [ -f "$source" ] || refuse "font $source is missing; run npm ci in site/"
    cp "$source" "$dist/fonts/"
  done
}

[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || refuse "version '$version' is not vMAJOR.MINOR.PATCH"
[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || refuse "checksum is not 64 lowercase hex characters"

rm -rf "$dist"
cp -R "$site_root/public" "$dist"
copyFonts
find "$dist" -name '*.html' -exec sed -i.bak -e "s/{{RELEASE_VERSION}}/$version/g" -e "s/{{RELEASE_SHA256}}/$sha256/g" {} +
find "$dist" -name '*.bak' -delete
# -I skips binary files: a woff2 font can hold the bytes "{{" by chance.
if grep -rlI '{{' "$dist" >/dev/null 2>&1; then
  refuse "a placeholder survived the build"
fi
echo "built $dist for $version"
