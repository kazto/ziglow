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

/// If the trimmed `line` is exactly one Markdown image `![alt](dest)` and
/// nothing else, return the destination (title and surrounding `<>` stripped).
/// Otherwise null. Only standalone image lines are eligible.
fn parseStandaloneImage(line: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t\r\n");
    if (!std.mem.startsWith(u8, t, "![")) return null;
    if (t.len == 0 or t[t.len - 1] != ')') return null; // nothing after the image

    const close_alt = std.mem.indexOf(u8, t, "](") orelse return null;
    var dest = std.mem.trim(u8, t[close_alt + 2 .. t.len - 1], " \t");
    dest = stripTitle(dest);
    if (dest.len >= 2 and dest[0] == '<' and dest[dest.len - 1] == '>') {
        dest = dest[1 .. dest.len - 1];
    }
    dest = std.mem.trim(u8, dest, " \t");
    if (dest.len == 0) return null;
    return dest;
}

/// Strip a trailing `"title"` / `'title'` (separated from the dest by
/// whitespace) from a link destination. Returns `dest` unchanged otherwise.
fn stripTitle(dest: []const u8) []const u8 {
    const trimmed = std.mem.trimRight(u8, dest, " \t");
    if (trimmed.len < 2) return trimmed;
    const quote = trimmed[trimmed.len - 1];
    if (quote != '"' and quote != '\'') return trimmed;
    const open = std.mem.lastIndexOfScalar(u8, trimmed[0 .. trimmed.len - 1], quote) orelse return trimmed;
    if (open == 0) return trimmed;
    if (trimmed[open - 1] != ' ' and trimmed[open - 1] != '\t') return trimmed;
    return std.mem.trimRight(u8, trimmed[0..open], " \t");
}

test "parseStandaloneImage extracts dest from a lone image line" {
    try std.testing.expectEqualStrings("a.png", parseStandaloneImage("![alt](a.png)").?);
    try std.testing.expectEqualStrings("a.png", parseStandaloneImage("  ![](a.png)  ").?);
    try std.testing.expectEqualStrings("a.png", parseStandaloneImage("![cap](a.png \"title\")").?);
    try std.testing.expectEqualStrings("a.png", parseStandaloneImage("![cap](a.png 'title')").?);
    try std.testing.expectEqualStrings("a b.png", parseStandaloneImage("![x](<a b.png>)").?);
}

test "parseStandaloneImage rejects non-standalone or non-image lines" {
    try std.testing.expect(parseStandaloneImage("text ![a](a.png) more") == null);
    try std.testing.expect(parseStandaloneImage("![a](a.png) trailing") == null);
    try std.testing.expect(parseStandaloneImage("a link [x](y)") == null);
    try std.testing.expect(parseStandaloneImage("just text") == null);
    try std.testing.expect(parseStandaloneImage("![empty]()") == null);
}
