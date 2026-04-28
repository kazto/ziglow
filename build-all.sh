#!/bin/bash
set -e

VERSION="v0.2.1"
DIST_DIR="dist"

mkdir -p $DIST_DIR

# Linux x86_64
echo "Building Linux x86_64..."
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast
tar -czf $DIST_DIR/ziglow-$VERSION-x86_64-linux.tar.gz -C zig-out/bin ziglow

# Linux aarch64
echo "Building Linux aarch64..."
zig build -Dtarget=aarch64-linux -Doptimize=ReleaseFast
tar -czf $DIST_DIR/ziglow-$VERSION-aarch64-linux.tar.gz -C zig-out/bin ziglow

# macOS x86_64
echo "Building macOS x86_64..."
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseFast
tar -czf $DIST_DIR/ziglow-$VERSION-x86_64-macos.tar.gz -C zig-out/bin ziglow

# macOS aarch64
echo "Building macOS aarch64..."
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast
tar -czf $DIST_DIR/ziglow-$VERSION-aarch64-macos.tar.gz -C zig-out/bin ziglow

# Windows x86_64
echo "Building Windows x86_64..."
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
zip -j $DIST_DIR/ziglow-$VERSION-x86_64-windows.zip zig-out/bin/ziglow.exe

# Windows aarch64
echo "Building Windows aarch64..."
zig build -Dtarget=aarch64-windows-gnu -Doptimize=ReleaseFast
zip -j $DIST_DIR/ziglow-$VERSION-aarch64-windows.zip zig-out/bin/ziglow.exe

echo "Build complete! Artifacts are in $DIST_DIR/"
