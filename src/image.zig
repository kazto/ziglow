//! Standalone-line Markdown image extraction for ziglow.
//! Scans Markdown for lines that are exactly one `![alt](path)` image,
//! replaces each with a unique marker, and records the resolved local path.
//! Fenced code blocks are skipped. Mirrors the `mermaid.zig` pipeline.
const std = @import("std");
const mermaid = @import("mermaid.zig");
const imagesize = @import("imagesize.zig");

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

/// One extracted standalone image, with the cell box the terminal should draw
/// and the markers that reserve that many rows in the rendered text flow.
pub const Img = struct {
    /// Marker whose rendered line is swapped for the inline-image escape.
    primary: []u8,
    /// Extra markers (blanked to "") whose paragraphs reserve the remaining
    /// rows of the image's height so following content is not overdrawn.
    spacers: [][]u8,
    /// File contents (null when the image could not be read).
    bytes: ?[]u8,
    /// Cell box; 0 means "unknown" (terminal falls back to natural size).
    cols: u32,
    rows: u32,

    fn deinit(self: *Img, allocator: std.mem.Allocator) void {
        allocator.free(self.primary);
        for (self.spacers) |s| allocator.free(s);
        allocator.free(self.spacers);
        if (self.bytes) |b| allocator.free(b);
    }
};

pub const ImageResult = struct {
    /// Markdown with each standalone image line replaced by its marker block.
    markdown: []u8,
    images: []Img,

    pub fn deinit(self: *ImageResult, allocator: std.mem.Allocator) void {
        allocator.free(self.markdown);
        for (self.images) |*img| img.deinit(allocator);
        allocator.free(self.images);
    }
};

/// Each marker paragraph occupies two rendered rows (one content row plus the
/// blank zchomd inserts between block elements), and zchomd adds a further
/// ~3-row bottom margin after the whole block. So floor(rows / 2) paragraphs
/// reserve just under the image's height, and that trailing margin makes up the
/// difference — placing following content one row below the image with no gap,
/// rather than the 3 extra blank rows ceil(rows / 2) would leave.
const rows_per_marker = 2;

fn readImageFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(allocator, 32 * 1024 * 1024) catch null;
}

/// Cell box for an image, preserving aspect: natural size (image px / cell px)
/// unless that exceeds `max_cols` / `max_rows`, in which case it is scaled down.
/// `cell_w` / `cell_h` of 0 mean "unknown" → returns {0,0} (natural-size path).
fn cellBox(img_w: u32, img_h: u32, cell_w: f64, cell_h: f64, max_cols: u32, max_rows: u32) struct { cols: u32, rows: u32 } {
    if (cell_w <= 0 or cell_h <= 0 or img_w == 0 or img_h == 0) return .{ .cols = 0, .rows = 0 };
    const nat_w = @as(f64, @floatFromInt(img_w)) / cell_w;
    const nat_h = @as(f64, @floatFromInt(img_h)) / cell_h;
    var scale: f64 = 1.0;
    if (max_cols > 0) scale = @min(scale, @as(f64, @floatFromInt(max_cols)) / nat_w);
    if (max_rows > 0) scale = @min(scale, @as(f64, @floatFromInt(max_rows)) / nat_h);
    var cols: u32 = @intFromFloat(@ceil(nat_w * scale));
    var rows: u32 = @intFromFloat(@ceil(nat_h * scale));
    if (cols < 1) cols = 1;
    if (rows < 1) rows = 1;
    if (max_cols > 0 and cols > max_cols) cols = max_cols;
    if (max_rows > 0 and rows > max_rows) rows = max_rows;
    return .{ .cols = cols, .rows = rows };
}

/// Scan `md` for standalone local-image lines (outside fenced code blocks),
/// replace each with a marker block, read the file, and compute the cell box
/// the terminal should draw (so its height matches the reserved rows). When
/// `cell_w`/`cell_h` are 0 the image keeps natural size and reserves one row.
/// Caller owns the result.
pub fn extract(
    allocator: std.mem.Allocator,
    md: []const u8,
    base_dir: ?[]const u8,
    cell_w: f64,
    cell_h: f64,
    max_cols: u32,
    max_rows: u32,
) !ImageResult {
    var images: std.ArrayList(Img) = .empty;
    var out: std.ArrayList(u8) = .empty;
    var next_marker: usize = 0;
    errdefer {
        for (images.items) |*img| img.deinit(allocator);
        images.deinit(allocator);
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
                const resolved = try resolvePath(allocator, base_dir, dest);
                const bytes = readImageFile(allocator, resolved);
                allocator.free(resolved);

                var cols: u32 = 0;
                var rows: u32 = 0;
                if (bytes) |b| {
                    if (imagesize.dimensions(b)) |d| {
                        const box = cellBox(d.w, d.h, cell_w, cell_h, max_cols, max_rows);
                        cols = box.cols;
                        rows = box.rows;
                    }
                }

                // Reserve floor(rows / rows_per_marker) marker paragraphs (≥1);
                // zchomd's block bottom margin covers the remaining ~1 row.
                const n_markers: usize = if (rows > 0)
                    @max(1, rows / rows_per_marker)
                else
                    1;

                var img: Img = .{
                    .primary = undefined,
                    .spacers = &.{},
                    .bytes = bytes,
                    .cols = cols,
                    .rows = rows,
                };
                img.primary = try std.fmt.allocPrint(allocator, "{s}{d}", .{ marker_prefix, next_marker });
                next_marker += 1;
                errdefer img.deinit(allocator);

                var spacers: std.ArrayList([]u8) = .empty;
                errdefer {
                    for (spacers.items) |s| allocator.free(s);
                    spacers.deinit(allocator);
                }
                var k: usize = 1;
                while (k < n_markers) : (k += 1) {
                    const m = try std.fmt.allocPrint(allocator, "{s}{d}", .{ marker_prefix, next_marker });
                    next_marker += 1;
                    try spacers.append(allocator, m);
                }
                img.spacers = try spacers.toOwnedSlice(allocator);

                // Emit each marker as its own block: leading blank, then the
                // markers separated by blank lines, so zchomd renders one per
                // row and replaceMarkers can match each line.
                try out.append(allocator, '\n');
                try out.appendSlice(allocator, img.primary);
                try out.appendSlice(allocator, "\n\n");
                for (img.spacers) |s| {
                    try out.appendSlice(allocator, s);
                    try out.appendSlice(allocator, "\n\n");
                }

                try images.append(allocator, img);
                continue;
            }
        }

        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }

    return ImageResult{
        .markdown = try out.toOwnedSlice(allocator),
        .images = try images.toOwnedSlice(allocator),
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
    // cell_w/cell_h = 0 → natural-size path: one marker, no spacers, no read.
    var res = try extract(a, md, null, 0, 0, 0, 0);
    defer res.deinit(a);

    try std.testing.expectEqual(@as(usize, 1), res.images.len);
    try std.testing.expectEqual(@as(usize, 0), res.images[0].spacers.len);
    try std.testing.expectEqualStrings("ZIGLOWIMAGE0", res.images[0].primary);
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
    var res = try extract(a, md, null, 0, 0, 0, 0);
    defer res.deinit(a);

    try std.testing.expectEqual(@as(usize, 0), res.images.len);
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
    var res = try extract(a, md, "base", 0, 0, 0, 0);
    defer res.deinit(a);

    try std.testing.expectEqual(@as(usize, 2), res.images.len);
    try std.testing.expectEqualStrings("ZIGLOWIMAGE0", res.images[0].primary);
    try std.testing.expectEqualStrings("ZIGLOWIMAGE1", res.images[1].primary);
}

test "cellBox keeps natural size when it fits" {
    // 400x400 px at an 11x24 cell → 37 cols x 17 rows; fits in 80x50.
    const box = cellBox(400, 400, 11, 24, 80, 50);
    try std.testing.expectEqual(@as(u32, 37), box.cols);
    try std.testing.expectEqual(@as(u32, 17), box.rows);
}

test "cellBox scales down preserving aspect when too wide" {
    // 2000x1000 px at 10x20 → 200x50 cells; width cap 80 → scale 0.4 → 80x20.
    const box = cellBox(2000, 1000, 10, 20, 80, 50);
    try std.testing.expectEqual(@as(u32, 80), box.cols);
    try std.testing.expectEqual(@as(u32, 20), box.rows);
}

test "cellBox returns zero (natural-size path) when cell size is unknown" {
    const box = cellBox(400, 400, 0, 0, 80, 50);
    try std.testing.expectEqual(@as(u32, 0), box.cols);
    try std.testing.expectEqual(@as(u32, 0), box.rows);
}
