//! Mermaid diagram extraction and rendering for ziglow.
//! Extraction: scans Markdown for ```mermaid fenced blocks.
//! Rendering:  delegates to the `mmdc` CLI (Mermaid CLI / Node.js).
const std = @import("std");
const termimage = @import("termimage.zig");

pub const marker_prefix = "ZIGLOWMERMAID";
pub const placeholder = "[mermaid diagram omitted]";

pub const MermaidResult = struct {
    /// One entry per extracted mermaid block (owned slices).
    blocks: [][]u8,
    /// Modified Markdown: mermaid blocks replaced by markers (or placeholder).
    markdown: []u8,
    /// Marker strings matching each block (only set when use_markers=true).
    markers: [][]u8,

    pub fn deinit(self: *MermaidResult, allocator: std.mem.Allocator) void {
        for (self.blocks) |b| allocator.free(b);
        allocator.free(self.blocks);
        allocator.free(self.markdown);
        for (self.markers) |m| allocator.free(m);
        allocator.free(self.markers);
    }
};

/// Extract mermaid fenced code blocks from `md`.
/// When `use_markers` is true, each block is replaced with a unique marker string
/// (for later image substitution).  Otherwise a human-readable placeholder is used.
pub fn extract(allocator: std.mem.Allocator, md: []const u8, use_markers: bool) !MermaidResult {
    var blocks: std.ArrayList([]u8) = .empty;
    var markers: std.ArrayList([]u8) = .empty;
    var out: std.ArrayList(u8) = .empty;
    errdefer {
        for (blocks.items) |b| allocator.free(b);
        blocks.deinit(allocator);
        for (markers.items) |m| allocator.free(m);
        markers.deinit(allocator);
        out.deinit(allocator);
    }

    var in_fence = false;
    var fence_char: u8 = '`';
    var fence_len: usize = 0;
    var is_mermaid = false;
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);

    // Pending substitution line written once the fence closes cleanly.
    var pending: ?[]u8 = null;
    // Original fence line kept for unclosed-fence rollback.
    var original_fence_line: []const u8 = "";

    var it = std.mem.splitScalar(u8, md, '\n');
    while (it.next()) |line| {
        if (!in_fence) {
            const stripped = stripIndent(line);
            if (detectFenceOpen(stripped)) |f| {
                in_fence = true;
                fence_char = f.ch;
                fence_len = f.len;
                const info = std.mem.trim(u8, stripped[f.len..], " \t");
                is_mermaid = std.mem.startsWith(u8, info, "mermaid");
                if (is_mermaid) {
                    original_fence_line = line;
                    if (use_markers) {
                        const marker = try std.fmt.allocPrint(
                            allocator,
                            "{s}{d}",
                            .{ marker_prefix, blocks.items.len },
                        );
                        try markers.append(allocator, marker);
                        pending = try allocator.dupe(u8, marker);
                    } else {
                        pending = try allocator.dupe(u8, placeholder);
                    }
                } else {
                    try out.appendSlice(allocator, line);
                    try out.append(allocator, '\n');
                }
            } else {
                try out.appendSlice(allocator, line);
                try out.append(allocator, '\n');
            }
            continue;
        }

        // Inside a fence ---
        if (isClosingFence(line, fence_char, fence_len)) {
            if (is_mermaid) {
                // Save block content (drop trailing newline).
                const raw = current.items;
                const block = if (raw.len > 0 and raw[raw.len - 1] == '\n')
                    raw[0 .. raw.len - 1]
                else
                    raw;
                try blocks.append(allocator, try allocator.dupe(u8, block));
                current.clearRetainingCapacity();
                if (pending) |p| {
                    try out.appendSlice(allocator, p);
                    try out.append(allocator, '\n');
                    allocator.free(p);
                    pending = null;
                }
            } else {
                try out.appendSlice(allocator, line);
                try out.append(allocator, '\n');
            }
            in_fence = false;
            is_mermaid = false;
            original_fence_line = "";
        } else {
            if (is_mermaid) {
                try current.appendSlice(allocator, line);
                try current.append(allocator, '\n');
            } else {
                try out.appendSlice(allocator, line);
                try out.append(allocator, '\n');
            }
        }
    }

    // Unclosed mermaid fence: roll back and restore original content.
    if (in_fence and is_mermaid) {
        if (use_markers and markers.items.len > 0) {
            if (markers.pop()) |last| allocator.free(last);
        }
        if (pending) |p| {
            allocator.free(p);
            pending = null;
        }
        try out.appendSlice(allocator, original_fence_line);
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, current.items);
    } else if (pending) |p| {
        allocator.free(p);
    }

    return MermaidResult{
        .blocks = try blocks.toOwnedSlice(allocator),
        .markdown = try out.toOwnedSlice(allocator),
        .markers = try markers.toOwnedSlice(allocator),
    };
}

// ── Fence helpers ─────────────────────────────────────────────────────────────

const FenceInfo = struct { ch: u8, len: usize };

fn detectFenceOpen(line: []const u8) ?FenceInfo {
    for ([_]u8{ '`', '~' }) |ch| {
        if (line.len >= 3 and line[0] == ch and line[1] == ch and line[2] == ch) {
            var n: usize = 3;
            while (n < line.len and line[n] == ch) : (n += 1) {}
            return .{ .ch = ch, .len = n };
        }
    }
    return null;
}

fn isClosingFence(line: []const u8, fence_char: u8, fence_len: usize) bool {
    const stripped = stripIndent(line);
    const trimmed = std.mem.trimRight(u8, stripped, " \t\r");
    if (trimmed.len < fence_len) return false;
    for (trimmed) |c| if (c != fence_char) return false;
    return true;
}

fn stripIndent(line: []const u8) []const u8 {
    var n: usize = 0;
    while (n < line.len and n < 3 and line[n] == ' ') : (n += 1) {}
    return line[n..];
}

// ── mmdc integration ──────────────────────────────────────────────────────────

/// Search PATH for the `mmdc` binary.  Returns an owned path, or null.
pub fn findMmdc(allocator: std.mem.Allocator) !?[]u8 {
    const path_env = termimage.getEnv("PATH") orelse return null;
    var dir_it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (dir_it.next()) |dir| {
        const full = try std.fs.path.join(allocator, &.{ dir, "mmdc" });
        errdefer allocator.free(full);
        std.fs.accessAbsolute(full, .{}) catch {
            allocator.free(full);
            continue;
        };
        return full;
    }
    return null;
}

/// Render a single mermaid diagram source to PNG using mmdc.
/// Returns owned PNG bytes, or null on any failure.
pub fn renderPNG(
    allocator: std.mem.Allocator,
    diagram: []const u8,
    mmdc_path: []const u8,
) !?[]u8 {
    // Build unique temp paths.
    const ts: u64 = @bitCast(std.time.milliTimestamp());
    const tmp_in = try std.fmt.allocPrint(allocator, "/tmp/ziglow_{x}.mmd", .{ts});
    defer allocator.free(tmp_in);
    const tmp_out = try std.fmt.allocPrint(allocator, "/tmp/ziglow_{x}.png", .{ts +% 1});
    defer allocator.free(tmp_out);
    const tmp_pup = try std.fmt.allocPrint(allocator, "/tmp/ziglow_{x}.json", .{ts +% 2});
    defer allocator.free(tmp_pup);

    defer std.fs.deleteFileAbsolute(tmp_in) catch {};
    defer std.fs.deleteFileAbsolute(tmp_out) catch {};
    defer std.fs.deleteFileAbsolute(tmp_pup) catch {};

    // Write diagram source.
    {
        const f = std.fs.createFileAbsolute(tmp_in, .{}) catch return null;
        defer f.close();
        f.writeAll(diagram) catch return null;
    }

    // Write puppeteer config to avoid sandbox issues on Linux.
    {
        const f = std.fs.createFileAbsolute(tmp_pup, .{}) catch return null;
        defer f.close();
        f.writeAll("{\"args\":[\"--no-sandbox\"]}") catch return null;
    }

    // Run mmdc.
    var child = std.process.Child.init(
        &.{ mmdc_path, "-p", tmp_pup, "-i", tmp_in, "-o", tmp_out },
        allocator,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;
    const term = child.wait() catch return null;
    switch (term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    // Read PNG output.
    const f = std.fs.openFileAbsolute(tmp_out, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(allocator, 50 * 1024 * 1024) catch null;
}

/// Render all mermaid blocks.  Returns a slice (same length as `blocks`);
/// entries are null when rendering of that block failed.
pub fn renderPNGs(
    allocator: std.mem.Allocator,
    blocks: []const []u8,
    mmdc_path: []const u8,
) ![]?[]u8 {
    const images = try allocator.alloc(?[]u8, blocks.len);
    for (blocks, 0..) |block, i| {
        images[i] = try renderPNG(allocator, block, mmdc_path);
    }
    return images;
}
