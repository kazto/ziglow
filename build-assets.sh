#!/bin/sh

set -e

mkdir -p dist
rm -f dist/*.tar.zst

# Get version from build.zig.zon
version=$(grep -w '.version =' build.zig.zon | cut -d '"' -f 2)

# arch: x86_64, aarch64 / os: linux-musl, macos, windows-gnuでビルド
for arch in x86_64 aarch64
do
    for os in linux-musl macos windows-gnu
    do
        echo "Building for ${arch}-${os}..."
        zig build -Dtarget=${arch}-${os} -Doptimize=ReleaseSafe

        # Determine binary name (add .exe for windows)
        bin_name="ziglow"
        case $os in
            windows*) bin_name="ziglow.exe" ;;
        esac

        # tar zstdで./zig-out/bin/ziglow を圧縮
        # ziglow-${version}-${arch}-${os}.tar.zst を ./dist/ に配置
        tar --zstd -cf "dist/ziglow-${version}-${arch}-${os}.tar.zst" -C zig-out/bin "$bin_name"
    done
done
