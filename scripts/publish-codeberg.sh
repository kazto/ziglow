#!/bin/sh

set -e

# Get version from build.zig.zon
version=$(grep -w '.version =' build.zig.zon | cut -d '"' -f 2)
tag="v${version}"

# Check if dist/ contains any assets
if [ ! -d "dist" ] || [ -z "$(ls -A dist/*.tar.zst 2>/dev/null)" ]; then
    echo "Error: No assets found in dist/. Please run build-assets.sh first."
    exit 1
fi

echo "Creating Codeberg release ${tag} using tea-cli..."

# Collect assets for tea-cli
assets=""
for asset in dist/*.tar.zst; do
    assets="${assets} --asset ${asset}"
done

# Create release and upload assets using tea-cli
# Note: This assumes tea-cli is configured (logged in) for Codeberg
# or the 'codeberg' remote is correctly set up.
tea-cli releases create \
    --remote codeberg \
    --tag "${tag}" \
    --title "${tag}" \
    --note "Release ${tag}" \
    ${assets}

echo "Successfully published to Codeberg!"
