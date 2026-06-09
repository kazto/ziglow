#!/bin/sh

set -e

# Get version from build.zig.zon
version=$(grep -w '.version =' build.zig.zon | cut -d '"' -f 2)

# Check if dist/ contains any assets
if [ ! -d "dist" ] || [ -z "$(ls -A dist/*.tar.zst 2>/dev/null)" ]; then
    echo "Error: No assets found in dist/. Please run build-assets.sh first."
    exit 1
fi

# gh でリリース
echo "Creating GitHub release v${version}..."
gh release create "v${version}" dist/*.tar.zst --title "v${version}" --generate-notes
