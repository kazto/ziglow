//! Standalone-line Markdown image extraction for ziglow.
//! Scans Markdown for lines that are exactly one `![alt](path)` image,
//! replaces each with a unique marker, and records the resolved local path.
//! Fenced code blocks are skipped. Mirrors the `mermaid.zig` pipeline.
const std = @import("std");
const mermaid = @import("mermaid.zig");

pub const marker_prefix = "ZIGLOWIMAGE";

/// Allowed raster image extensions (lower-cased, sans dot).
const allowed_exts = [_][]const u8{ "png", "jpg", "jpeg", "gif", "bmp", "webp" };

/// True when `path`'s basename ends in one of `allowed_exts` (case-insensitive).
fn isImageExt(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return false;
    const ext = base[dot + 1 ..];
    if (ext.len == 0 or ext.len > 8) return false;
    var buf: [8]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..ext.len], ext);
    for (allowed_exts) |e| if (std.mem.eql(u8, lower, e)) return true;
    return false;
}

/// True when `path` looks like a URL / non-local scheme we must not read.
fn isUrl(path: []const u8) bool {
    const schemes = [_][]const u8{ "http://", "https://", "data:", "ftp://", "file://" };
    for (schemes) |s| {
        if (path.len >= s.len and std.ascii.eqlIgnoreCase(path[0..s.len], s)) return true;
    }
    return false;
}

test "isImageExt accepts allowed raster formats, rejects others" {
    try std.testing.expect(isImageExt("a.png"));
    try std.testing.expect(isImageExt("dir/sub/photo.JPG"));
    try std.testing.expect(isImageExt("x.jpeg"));
    try std.testing.expect(isImageExt("x.webp"));
    try std.testing.expect(!isImageExt("notes.txt"));
    try std.testing.expect(!isImageExt("noext"));
    try std.testing.expect(!isImageExt("archive.tar.gz"));
    // A dot in a parent dir must not be treated as the extension.
    try std.testing.expect(!isImageExt("v1.2/file"));
}

test "isUrl detects remote / non-local schemes" {
    try std.testing.expect(isUrl("http://example.com/a.png"));
    try std.testing.expect(isUrl("HTTPS://example.com/a.png"));
    try std.testing.expect(isUrl("data:image/png;base64,AAAA"));
    try std.testing.expect(!isUrl("./local.png"));
    try std.testing.expect(!isUrl("/abs/local.png"));
    try std.testing.expect(!isUrl("C:\\imgs\\local.png"));
}
