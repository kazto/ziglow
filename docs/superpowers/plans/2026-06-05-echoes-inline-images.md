# Echoes Inline Markdown Images Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render standalone-line local Markdown images `![alt](path)` inline via the Kitty Graphics Protocol when running in Echoes (or any `.kitty`/`.iterm2`/`.sixel` terminal).

**Architecture:** Mirror the existing mermaid pipeline. A new `src/image.zig` scans the Markdown line-by-line (skipping fenced code blocks), detects lines that are exactly one image, replaces each with a unique marker, and records the resolved file path. After zchomd renders the markdown, the image files are read and `termimage.replaceMarkers` swaps each marker line for the encoded image. The mermaid and image marker sets are merged and substituted in a single `replaceMarkers` call so both can coexist.

**Tech Stack:** Zig 0.15.2, existing `termimage.zig` (detection + Kitty/iTerm2/Sixel encoding), `mermaid.zig` (fence-scanning pattern reused).

---

## File Structure

- `src/mermaid.zig` (modify): make the fence helpers `pub` so `image.zig` can reuse them (DRY).
- `src/image.zig` (create): standalone-image detection, path resolution, and `extract` orchestration. One responsibility: turning Markdown into (substituted-markdown, markers, paths).
- `src/main.zig` (modify): new `renderTerminal` helper that merges the mermaid + image marker sets and calls `replaceMarkers` once; thread a `base_dir` argument through `processContent`/`processFile`.

---

## Task 1: Make mermaid fence helpers reusable

**Files:**
- Modify: `src/mermaid.zig` (the `FenceInfo` struct and `detectFenceOpen`/`isClosingFence`/`stripIndent` functions, around lines 148-173)

- [ ] **Step 1: Make the fence helpers and their struct `pub`**

In `src/mermaid.zig`, change these four declarations from private to `pub` (add `pub ` in front; bodies unchanged):

```zig
pub const FenceInfo = struct { ch: u8, len: usize };

pub fn detectFenceOpen(line: []const u8) ?FenceInfo {
```

```zig
pub fn isClosingFence(line: []const u8, fence_char: u8, fence_len: usize) bool {
```

```zig
pub fn stripIndent(line: []const u8) []const u8 {
```

- [ ] **Step 2: Verify it still builds**

Run: `zig build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add src/mermaid.zig
git commit -m "refactor: expose mermaid fence helpers for reuse"
```

---

## Task 2: Image extension and URL filters

**Files:**
- Create: `src/image.zig`
- Modify: `src/main.zig` (add the import so the new file's tests run under `zig build test`)

- [ ] **Step 1: Create `src/image.zig` with the two pure filters and their tests**

```zig
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
```

- [ ] **Step 2: Import `image.zig` in main.zig so its tests compile and run**

In `src/main.zig`, next to the other imports (after `const termimage = @import("termimage.zig");` on line 9), add:

```zig
const image = @import("image.zig");
```

- [ ] **Step 3: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS (the two new `image.zig` tests run via the main test module).

- [ ] **Step 4: Commit**

```bash
git add src/image.zig src/main.zig
git commit -m "feat: add image extension and URL filters"
```

---

## Task 3: Standalone-image line parser

**Files:**
- Modify: `src/image.zig`

- [ ] **Step 1: Write the failing tests for `parseStandaloneImage`**

Add to `src/image.zig` (tests reference functions added in Step 3):

```zig
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: FAIL — `parseStandaloneImage` / `stripTitle` not defined (compile error).

- [ ] **Step 3: Implement `parseStandaloneImage` and `stripTitle`**

Add to `src/image.zig`:

```zig
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/image.zig
git commit -m "feat: add standalone image line parser"
```

---

## Task 4: Path resolution

**Files:**
- Modify: `src/image.zig`

- [ ] **Step 1: Write the failing tests for `resolvePath`**

Add to `src/image.zig`:

```zig
test "resolvePath joins relative paths against base_dir and passes absolutes through" {
    const a = std.testing.allocator;

    const rel = try resolvePath(a, "docs", "img/a.png");
    defer a.free(rel);
    try std.testing.expectEqualStrings("docs" ++ std.fs.path.sep_str ++ "img" ++ std.fs.path.sep_str ++ "a.png", rel);

    const no_base = try resolvePath(a, null, "a.png");
    defer a.free(no_base);
    try std.testing.expectEqualStrings("a.png", no_base);

    const abs_input = if (@import("builtin").os.tag == .windows) "C:\\imgs\\a.png" else "/imgs/a.png";
    const abs = try resolvePath(a, "docs", abs_input);
    defer a.free(abs);
    try std.testing.expectEqualStrings(abs_input, abs);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: FAIL — `resolvePath` not defined.

- [ ] **Step 3: Implement `resolvePath`**

Add to `src/image.zig`:

```zig
/// Resolve `path` for reading. Absolute paths are duped as-is; relative paths
/// are joined against `base_dir` (the Markdown file's directory), or returned
/// as-is (relative to CWD) when `base_dir` is null. Caller owns the result.
fn resolvePath(allocator: std.mem.Allocator, base_dir: ?[]const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const base = base_dir orelse return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ base, path });
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/image.zig
git commit -m "feat: add image path resolution"
```

---

## Task 5: `extract` orchestration

**Files:**
- Modify: `src/image.zig`

- [ ] **Step 1: Write the failing tests for `extract`**

Add to `src/image.zig`:

```zig
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
    // The marker appears in the rewritten markdown; the original image does not.
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
    // Nothing was rewritten; all originals survive.
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
    try std.testing.expectEqualStrings("base" ++ std.fs.path.sep_str ++ "a.png", res.paths[0]);
    try std.testing.expectEqualStrings("base" ++ std.fs.path.sep_str ++ "sub" ++ std.fs.path.sep_str ++ "b.jpg", res.paths[1]);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test`
Expected: FAIL — `extract` / `ImageResult` not defined.

- [ ] **Step 3: Implement `ImageResult` and `extract`**

Add to `src/image.zig`:

```zig
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
                try paths.append(allocator, resolved);
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test`
Expected: PASS (all `image.zig` tests).

- [ ] **Step 5: Commit**

```bash
git add src/image.zig
git commit -m "feat: add standalone image extraction orchestration"
```

---

## Task 6: Wire image rendering into main.zig

**Files:**
- Modify: `src/main.zig` (`processContent` around lines 190-292; `processFile` around lines 164-186; the two stdin dispatch sites around lines 113-128)

- [ ] **Step 1: Add the `renderTerminal` and `readImageFile` helpers**

In `src/main.zig`, add these two functions immediately above `fn processContent` (before line 188's doc comment). `zchomd`, `termimage`, `mermaid`, and `image` are already imported at the top of the file.

```zig
/// Read an image file for inline display. Returns null (caller keeps the marker
/// line) on any open/read failure or oversize file.
fn readImageFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(allocator, 32 * 1024 * 1024) catch null;
}

/// Render `content` for a TTY, substituting mermaid diagrams and standalone
/// local images with inline graphics. Merges both marker sets and calls
/// `replaceMarkers` once. Returns an owned rendered string.
fn renderTerminal(
    allocator: std.mem.Allocator,
    tr: *zchomd.TermRenderer,
    content: []const u8,
    has_mermaid: bool,
    img_format: termimage.Format,
    word_wrap: u32,
    base_dir: ?[]const u8,
) ![]u8 {
    // No image-capable terminal: render as-is (mermaid shows as a code block).
    if (img_format == .none) return tr.renderAlloc(content);

    // ── Stage 1: mermaid extraction (optional) ──
    var mermaid_markers: []const []const u8 = &.{};
    var mermaid_pngs: []?[]u8 = &.{};
    var mres: ?mermaid.MermaidResult = null;
    defer if (mres) |*r| r.deinit(allocator);
    var pngs: ?[]?[]u8 = null;
    defer if (pngs) |p| {
        for (p) |x| if (x) |b| allocator.free(b);
        allocator.free(p);
    };

    var md1: []const u8 = content;
    if (has_mermaid) {
        if (try mermaid.findMmdc(allocator)) |mmdc| {
            defer allocator.free(mmdc);
            var r = try mermaid.extract(allocator, content, true);
            if (r.blocks.len > 0) {
                pngs = try mermaid.renderPNGs(allocator, r.blocks, mmdc);
                mermaid_pngs = pngs.?;
                mermaid_markers = r.markers;
                md1 = r.markdown;
                mres = r;
            } else {
                r.deinit(allocator);
            }
        }
    }

    // ── Stage 2: image extraction ──
    var img = try image.extract(allocator, md1, base_dir);
    defer img.deinit(allocator);

    // ── Render the fully-substituted markdown ──
    const md_rendered = try tr.renderAlloc(img.markdown);
    defer allocator.free(md_rendered);

    // Fast path: nothing to substitute.
    if (mermaid_markers.len == 0 and img.markers.len == 0) {
        return allocator.dupe(u8, md_rendered);
    }

    // ── Read image files into bytes (null on failure) ──
    const img_bytes = try allocator.alloc(?[]u8, img.paths.len);
    defer {
        for (img_bytes) |b| if (b) |v| allocator.free(v);
        allocator.free(img_bytes);
    }
    for (img.paths, 0..) |p, i| img_bytes[i] = readImageFile(allocator, p);

    // ── Merge marker + image sets and substitute once ──
    var all_markers: std.ArrayList([]const u8) = .empty;
    defer all_markers.deinit(allocator);
    var all_images: std.ArrayList(?[]u8) = .empty;
    defer all_images.deinit(allocator);

    for (mermaid_markers) |m| try all_markers.append(allocator, m);
    for (mermaid_pngs) |p| try all_images.append(allocator, p);
    for (img.markers) |m| try all_markers.append(allocator, m);
    for (img_bytes) |b| try all_images.append(allocator, b);

    return termimage.replaceMarkers(
        allocator,
        md_rendered,
        all_markers.items,
        all_images.items,
        img_format,
        word_wrap,
    );
}
```

- [ ] **Step 2: Replace the `rendered` block in `processContent` to use `renderTerminal`**

In `src/main.zig`, change `processContent`'s signature to accept `base_dir` (add the parameter after `is_terminal`):

```zig
fn processContent(
    allocator: std.mem.Allocator,
    content: []const u8,
    style_name: []const u8,
    word_wrap: u32,
    use_pager: bool,
    use_tui: bool,
    is_terminal: bool,
    base_dir: ?[]const u8,
    conf: config.Config,
) !void {
```

Then replace the entire `const rendered: []u8 = blk: { ... };` expression (currently lines 215-265, from `const rendered` through the closing `};`) with:

```zig
    const rendered: []u8 = blk: {
        const has_mermaid = std.mem.indexOf(u8, normalized_content, "```mermaid") != null;

        if (is_terminal) {
            break :blk try renderTerminal(allocator, &tr, normalized_content, has_mermaid, img_format, word_wrap, base_dir);
        }

        // Piped output: replace mermaid blocks with placeholder text.
        if (has_mermaid) {
            var result = try mermaid.extract(allocator, normalized_content, false);
            defer result.deinit(allocator);
            break :blk try tr.renderAlloc(result.markdown);
        }
        break :blk try tr.renderAlloc(normalized_content);
    };
```

- [ ] **Step 3: Update `processFile` to compute and pass `base_dir`**

In `src/main.zig`, change `processFile`'s signature to add `base_dir`-less call-through — i.e. compute the directory from `path` and pass it. Replace the final `try processContent(...)` line in `processFile` (currently line 185) with:

```zig
    const base_dir = std.fs.path.dirname(path);
    try processContent(allocator, content, style_name, word_wrap, use_pager, use_tui, is_terminal, base_dir, conf);
```

- [ ] **Step 4: Update the two stdin dispatch sites to pass `null` base_dir**

In `src/main.zig`, the piped-stdin path (around line 117) and the `-` path (around line 126) both call `processContent`. Add a `null` argument before `conf` in each:

```zig
        try processContent(allocator, content, effective_style, width, use_pager, use_tui, is_terminal, null, conf);
```

(Apply to both call sites.)

- [ ] **Step 5: Build and run the full test suite**

Run: `zig build && zig build test`
Expected: builds clean; all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add src/main.zig
git commit -m "feat: render standalone Markdown images inline in terminals"
```

---

## Task 7: Manual smoke test (non-image terminal must not crash)

**Files:**
- None (manual verification)

- [ ] **Step 1: Build the release binary**

Run: `zig build`
Expected: produces `zig-out/bin/ziglow.exe`.

- [ ] **Step 2: Create a temp Markdown with a standalone local image**

```bash
mkdir -p tmp/img-smoke
```

Write `tmp/img-smoke/doc.md` with:

```markdown
# Image test

![a cat](cat.png)

Trailing paragraph.
```

Place any small PNG at `tmp/img-smoke/cat.png` (e.g. copy an existing PNG).

- [ ] **Step 3: Run against a pipe (no TTY) and confirm no crash / no escape garbage**

Run: `zig-out/bin/ziglow.exe tmp/img-smoke/doc.md | cat`
Expected: exits 0; the image line shows as text (notty style, `img_format == .none` → marker logic skipped); no Kitty escape bytes in piped output.

---

## Task 8: Visual verification in Echoes + record findings

**Files:**
- Verification harness in `tmp/echoes-verify/` (see the `verification-method` memory)
- Update memory after the result is known

- [ ] **Step 1: Capture a screenshot of the doc rendered in Echoes**

Use the existing harness (per the `verification-method` memory):

Run (PowerShell):
```powershell
tmp/echoes-verify/capture.ps1 -Command 'zig-out\bin\ziglow.exe tmp\img-smoke\doc.md' -Out tmp\echoes-verify\img-out.png
```

Read the resulting PNG with the Read tool.

- [ ] **Step 2: Confirm the image renders inline**

Expected: the cat PNG appears inline where the `![a cat](cat.png)` line was, rendered via the Kitty Graphics Protocol (APC `\x1b_G…`). The heading and trailing paragraph render normally.

- [ ] **Step 3: Record the outcome in memory**

If it renders: add a short note to the relevant memory file that standalone local images now display via Kitty Graphics in Echoes on Windows, and whether ConPTY passes the APC graphics sequences through cleanly (unlike OSC 66). If ConPTY mangles the APC frames the same way it does OSC 66, record that as an Echoes-side limitation (not fixable from ziglow), linking `[[conpty-breaks-osc66]]`.

- [ ] **Step 4: Commit any harness or doc updates**

```bash
git add -A
git commit -m "test: verify Echoes inline image rendering"
```

---

## Notes for the implementer

- Zig version is 0.15.2. Use the `std.ArrayList(T) = .empty` + `append(allocator, x)` + `toOwnedSlice(allocator)` + `deinit(allocator)` idioms exactly as `src/mermaid.zig` does.
- `replaceMarkers`, `encode`, and `encodeKitty` in `termimage.zig` are unchanged — encoding passes the raw file bytes with `f=100`, which Echoes' GdiPlus decoder handles for png/jpg/gif/bmp/webp.
- The marker is emitted surrounded by blank lines so zchomd renders it as its own paragraph line; `replaceMarkers` strips ANSI + trims each output line before matching, exactly as it does for mermaid markers.
- Do not add HTTP fetching, reference-style image support, or multi-image-per-line handling — explicitly out of scope (YAGNI).
