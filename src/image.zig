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

/// True when `path` carries a URL scheme we do not handle as a local file.
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
    // The image must be the whole line: the first `)` at/after the dest must
    // be the final character. Otherwise there is trailing content or a second
    // image (e.g. `![a](x.png)![b](y.png)`).
    const close_paren = std.mem.indexOfScalarPos(u8, t, close_alt + 2, ')') orelse return null;
    if (close_paren != t.len - 1) return null;

    var dest = std.mem.trim(u8, t[close_alt + 2 .. close_paren], " \t");
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

test "parseStandaloneImage rejects multiple images on one line" {
    try std.testing.expect(parseStandaloneImage("![a](x.png)![b](y.png)") == null);
    try std.testing.expect(parseStandaloneImage("![a](x.png) ![b](y.png)") == null);
}

/// Resolve `path` for reading. Absolute paths are duped as-is; relative paths
/// are joined against `base_dir` (the Markdown file's directory), or returned
/// as-is (relative to CWD) when `base_dir` is null. Caller owns the result.
fn resolvePath(allocator: std.mem.Allocator, base_dir: ?[]const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const base = base_dir orelse return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ base, path });
}

test "resolvePath joins relative paths against base_dir and passes absolutes through" {
    const a = std.testing.allocator;

    const rel = try resolvePath(a, "docs", "a.png");
    defer a.free(rel);
    try std.testing.expectEqualStrings("docs" ++ std.fs.path.sep_str ++ "a.png", rel);

    const no_base = try resolvePath(a, null, "a.png");
    defer a.free(no_base);
    try std.testing.expectEqualStrings("a.png", no_base);

    const abs_input = if (@import("builtin").os.tag == .windows) "C:\\imgs\\a.png" else "/imgs/a.png";
    const abs = try resolvePath(a, "docs", abs_input);
    defer a.free(abs);
    try std.testing.expectEqualStrings(abs_input, abs);
}

pub const ImageResult = struct {
    /// Markdown with each standalone image line replaced by its marker.
    markdown: []u8,
    /// Marker strings (parallel to `paths`).
    markers: [][]u8,
    /// Resolved local file paths (parallel to `markers`).
    paths: [][]u8,

    pub fn deinit(self: *ImageResult, allocator: std.mem.Allocator) void {
        allocator.free(self.markdown);
        for (self.markers) |m| allocator.free(m);
        allocator.free(self.markers);
        for (self.paths) |p| allocator.free(p);
        allocator.free(self.paths);
    }
};

/// Scan `md` for standalone local-image lines (outside fenced code blocks),
/// replace each with a unique marker, and resolve its path against `base_dir`.
/// Non-image extensions and URLs are left untouched. Caller owns the result.
pub fn extract(allocator: std.mem.Allocator, md: []const u8, base_dir: ?[]const u8) !ImageResult {
    var markers: std.ArrayList([]u8) = .empty;
    var paths: std.ArrayList([]u8) = .empty;
    var out: std.ArrayList(u8) = .empty;
    errdefer {
        for (markers.items) |m| allocator.free(m);
        markers.deinit(allocator);
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
        out.deinit(allocator);
    }

    var in_fence = false;
    var fence_char: u8 = '`';
    var fence_len: usize = 0;

    var it = std.mem.splitScalar(u8, md, '\n');
    while (it.next()) |line| {
        if (in_fence) {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            if (mermaid.isClosingFence(line, fence_char, fence_len)) in_fence = false;
            continue;
        }

        const stripped = mermaid.stripIndent(line);
        if (mermaid.detectFenceOpen(stripped)) |f| {
            in_fence = true;
            fence_char = f.ch;
            fence_len = f.len;
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            continue;
        }

        if (parseStandaloneImage(line)) |dest| {
            if (!isUrl(dest) and isImageExt(dest)) {
                const marker = try std.fmt.allocPrint(allocator, "{s}{d}", .{ marker_prefix, markers.items.len });
                // Free `marker` if path resolution fails before it is appended;
                // once appended, the outer errdefer owns it (avoids double-free).
                const resolved = resolvePath(allocator, base_dir, dest) catch |e| {
                    allocator.free(marker);
                    return e;
                };
                try markers.append(allocator, marker);
                // `resolved` is not yet owned by the list; free it if this append
                // fails (OOM) so it doesn't leak. `marker` is already in `markers`,
                // owned by the outer errdefer.
                paths.append(allocator, resolved) catch |e| {
                    allocator.free(resolved);
                    return e;
                };
                // Emit the marker as its own block (blank lines guarantee zchomd
                // renders it on a line by itself so replaceMarkers can match it).
                try out.append(allocator, '\n');
                try out.appendSlice(allocator, marker);
                try out.appendSlice(allocator, "\n\n");
                continue;
            }
        }

        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }

    return ImageResult{
        .markdown = try out.toOwnedSlice(allocator),
        .markers = try markers.toOwnedSlice(allocator),
        .paths = try paths.toOwnedSlice(allocator),
    };
}

test "extract replaces standalone local images with markers and records paths" {
    const a = std.testing.allocator;
    const md =
        \\# Title
        \\
        \\![cap](pic.png)
        \\
        \\Some text.
        \\
    ;
    var res = try extract(a, md, null);
    defer res.deinit(a);

    try std.testing.expectEqual(@as(usize, 1), res.markers.len);
    try std.testing.expectEqual(@as(usize, 1), res.paths.len);
    try std.testing.expectEqualStrings("ZIGLOWIMAGE0", res.markers[0]);
    try std.testing.expectEqualStrings("pic.png", res.paths[0]);
    try std.testing.expect(std.mem.indexOf(u8, res.markdown, "ZIGLOWIMAGE0") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.markdown, "![cap]") == null);
}

test "extract skips fenced code, inline images, URLs, and non-image extensions" {
    const a = std.testing.allocator;
    const md =
        \\```
        \\![incode](no.png)
        \\```
        \\
        \\text ![inline](mid.png) text
        \\
        \\![remote](https://x/y.png)
        \\
        \\![doc](readme.txt)
        \\
    ;
    var res = try extract(a, md, null);
    defer res.deinit(a);

    try std.testing.expectEqual(@as(usize, 0), res.markers.len);
    try std.testing.expectEqual(@as(usize, 0), res.paths.len);
    try std.testing.expect(std.mem.indexOf(u8, res.markdown, "no.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.markdown, "mid.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.markdown, "y.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.markdown, "readme.txt") != null);
}

test "extract numbers multiple images and resolves against base_dir" {
    const a = std.testing.allocator;
    const md =
        \\![one](a.png)
        \\
        \\![two](sub/b.jpg)
        \\
    ;
    var res = try extract(a, md, "base");
    defer res.deinit(a);

    try std.testing.expectEqual(@as(usize, 2), res.markers.len);
    try std.testing.expectEqualStrings("ZIGLOWIMAGE0", res.markers[0]);
    try std.testing.expectEqualStrings("ZIGLOWIMAGE1", res.markers[1]);
    const exp0 = try std.fs.path.join(a, &.{ "base", "a.png" });
    defer a.free(exp0);
    const exp1 = try std.fs.path.join(a, &.{ "base", "sub/b.jpg" });
    defer a.free(exp1);
    try std.testing.expectEqualStrings(exp0, res.paths[0]);
    try std.testing.expectEqualStrings(exp1, res.paths[1]);
}
