//! Terminal image format detection and encoding.
//! Supports iTerm2 inline images, Kitty graphics protocol, and Sixel graphics.
const std = @import("std");
const builtin = @import("builtin");

fn getenv(name: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;
    return std.posix.getenv(name);
}

pub const Format = enum { none, iterm2, kitty, sixel };

/// Detect the terminal's inline image capability.
/// Pass whether stdout and stdin are TTYs.
pub fn detect(stdout_is_tty: bool, stdin_is_tty: bool) Format {
    if (!stdout_is_tty) return .none;

    // Explicit override.
    if (getenv("ZIGLOW_SIXEL")) |v|
        if (std.mem.eql(u8, v, "1")) return .sixel;
    if (getenv("GLOWM_SIXEL")) |v|
        if (std.mem.eql(u8, v, "1")) return .sixel;

    if (isIterm2()) return .iterm2;
    if (isKitty()) return .kitty;
    if (isKnownSixelTerminal()) return .sixel;

    // Query terminal via DA1 (Device Attributes) if stdin is available.
    if (stdin_is_tty and querySixelViaDA1()) return .sixel;

    return .none;
}

fn isIterm2() bool {
    const tp = getenv("TERM_PROGRAM") orelse return false;
    return std.mem.eql(u8, tp, "iTerm.app");
}

fn isKitty() bool {
    if (getenv("KITTY_WINDOW_ID") != null) return true;
    const term = getenv("TERM") orelse return false;
    return std.mem.indexOf(u8, term, "xterm-kitty") != null;
}

fn isKnownSixelTerminal() bool {
    if (builtin.os.tag == .windows) return false;
    if (getenv("TERM_PROGRAM")) |tp|
        if (std.mem.eql(u8, tp, "WezTerm")) return true;
    if (getenv("TERM")) |t| {
        const known = [_][]const u8{ "mlterm", "yaft-256color", "foot", "foot-direct", "contour" };
        for (known) |name| if (std.mem.eql(u8, t, name)) return true;
    }
    return false;
}

/// Query the terminal via DA1 (Primary Device Attributes) to check for Sixel support.
fn querySixelViaDA1() bool {
    if (builtin.os.tag == .windows) return false;
    const stdin_handle = std.posix.STDIN_FILENO;
    const stdout_handle = std.posix.STDOUT_FILENO;

    // Save terminal state and enter raw mode.
    const termios = std.posix.tcgetattr(stdin_handle) catch return false;
    var raw = termios;
    // Disable echoing and canonical mode.
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    // Set timeout (VMIN=0, VTIME=2 -> 200ms).
    raw.cc[@intFromEnum(std.posix.system.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.system.V.TIME)] = 2;

    std.posix.tcsetattr(stdin_handle, .FLUSH, raw) catch return false;
    defer std.posix.tcsetattr(stdin_handle, .FLUSH, termios) catch {};

    // Send Primary Device Attributes query.
    _ = std.posix.write(stdout_handle, "\x1b[c") catch return false;

    var buf: [64]u8 = undefined;
    const n = std.posix.read(stdin_handle, &buf) catch return false;
    if (n == 0) return false;

    return parseSixelSupport(buf[0..n]);
}

/// Parse DA1 response to see if Sixel (attribute 4) is supported.
/// Format: ESC [ ? P1 ; P2 ; ... c
fn parseSixelSupport(resp: []const u8) bool {
    const start = std.mem.indexOf(u8, resp, "\x1b[?") orelse return false;
    const end = std.mem.indexOfPos(u8, resp, start, "c") orelse return false;
    const params = resp[start + 3 .. end];

    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, "4")) return true;
    }
    return false;
}

// ── Encoding ──────────────────────────────────────────────────────────────────

/// Encode PNG bytes as a terminal image escape sequence.
/// Returns an owned string, or null for Format.none / encoding failure.
pub fn encode(
    allocator: std.mem.Allocator,
    format: Format,
    png: []const u8,
    width_cells: u32,
) !?[]u8 {
    return switch (format) {
        .none => null,
        .iterm2 => try encodeIterm2(allocator, png, width_cells),
        .kitty => try encodeKitty(allocator, png, width_cells),
        .sixel => try encodeSixel(allocator, png),
    };
}

fn encodeIterm2(allocator: std.mem.Allocator, png: []const u8, width_cells: u32) !?[]u8 {
    const Enc = std.base64.standard.Encoder;
    const b64_len = Enc.calcSize(png.len);
    const b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64);
    _ = Enc.encode(b64, png);

    return @as(?[]u8, if (width_cells > 0)
        try std.fmt.allocPrint(
            allocator,
            "\x1b]1337;File=inline=1;preserveAspectRatio=1;width={d}:{s}\x07\n",
            .{ width_cells, b64 },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "\x1b]1337;File=inline=1;preserveAspectRatio=1:{s}\x07\n",
            .{b64},
        ));
}

fn encodeKitty(allocator: std.mem.Allocator, png: []const u8, width_cells: u32) !?[]u8 {
    const Enc = std.base64.standard.Encoder;
    const b64_len = Enc.calcSize(png.len);
    const b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64);
    _ = Enc.encode(b64, png);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const chunk = 4096;
    var i: usize = 0;
    while (i < b64.len) {
        const end = @min(i + chunk, b64.len);
        const more: u8 = if (end < b64.len) '1' else '0';
        const header = if (i == 0)
            if (width_cells > 0)
                try std.fmt.allocPrint(
                    allocator,
                    "\x1b_Gf=100,a=T,c={d},m={c};",
                    .{ width_cells, more },
                )
            else
                try std.fmt.allocPrint(allocator, "\x1b_Gf=100,a=T,m={c};", .{more})
        else
            try std.fmt.allocPrint(allocator, "\x1b_Gm={c};", .{more});
        defer allocator.free(header);

        try out.appendSlice(allocator, header);
        try out.appendSlice(allocator, b64[i..end]);
        try out.appendSlice(allocator, "\x1b\\");
        i = end;
    }
    try out.append(allocator, '\n');
    return @as(?[]u8, try out.toOwnedSlice(allocator));
}

/// Encode PNG as Sixel by spawning img2sixel or ImageMagick convert.
fn encodeSixel(allocator: std.mem.Allocator, png: []const u8) !?[]u8 {
    const ts: u64 = @bitCast(std.time.milliTimestamp());
    const tmp = try std.fmt.allocPrint(allocator, "/tmp/ziglow_six_{x}.png", .{ts});
    defer allocator.free(tmp);
    defer std.fs.deleteFileAbsolute(tmp) catch {};

    {
        const f = std.fs.createFileAbsolute(tmp, .{}) catch return null;
        defer f.close();
        f.writeAll(png) catch return null;
    }

    // Try img2sixel first, then ImageMagick convert.
    const cmds = [_][]const []const u8{
        &.{ "img2sixel", tmp },
        &.{ "convert", tmp, "sixel:-" },
    };
    for (cmds) |argv| {
        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch continue;

        const output: ?[]u8 = if (child.stdout) |stdout|
            stdout.readToEndAlloc(allocator, 10 * 1024 * 1024) catch blk: {
                _ = child.wait() catch {};
                break :blk null;
            }
        else
            null;

        _ = child.wait() catch {};

        if (output) |o| {
            if (o.len > 0) return o;
            allocator.free(o);
        }
    }
    return null;
}

// ── Marker replacement ────────────────────────────────────────────────────────

/// Replace marker lines in `output` with encoded images.
/// `markers` and `images` are parallel slices; a null image keeps the original line.
/// Returns an owned string.
pub fn replaceMarkers(
    allocator: std.mem.Allocator,
    output: []const u8,
    markers: []const []const u8,
    images: []const ?[]u8,
    format: Format,
    width_cells: u32,
) ![]u8 {
    if (markers.len == 0) return allocator.dupe(u8, output);

    // Pre-encode images to avoid re-encoding per line.
    const encoded = try allocator.alloc(?[]u8, markers.len);
    defer {
        for (encoded) |e| if (e) |v| allocator.free(v);
        allocator.free(encoded);
    }
    for (0..markers.len) |i| {
        encoded[i] = if (i < images.len)
            if (images[i]) |png|
                encode(allocator, format, png, width_cells) catch null
            else
                null
        else
            null;
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var lines = std.mem.splitScalar(u8, output, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try result.append(allocator, '\n');
        first = false;

        // Strip ANSI + surrounding whitespace so the marker can be found.
        const plain = try stripAnsi(allocator, line);
        defer allocator.free(plain);
        const trimmed = std.mem.trim(u8, plain, " \t\r");

        var replaced = false;
        for (markers, 0..) |marker, i| {
            if (std.mem.eql(u8, trimmed, marker)) {
                if (encoded[i]) |img| {
                    try result.appendSlice(allocator, img);
                } else {
                    try result.appendSlice(allocator, line);
                }
                replaced = true;
                break;
            }
        }
        if (!replaced) try result.appendSlice(allocator, line);
    }
    return result.toOwnedSlice(allocator);
}

fn stripAnsi(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != 0x1b) {
            try out.append(allocator, s[i]);
            i += 1;
            continue;
        }
        if (i + 1 >= s.len) {
            i += 1;
            continue;
        }
        switch (s[i + 1]) {
            '[' => { // CSI: ESC [ ... <letter>
                i += 2;
                while (i < s.len and !std.ascii.isAlphabetic(s[i])) : (i += 1) {}
                if (i < s.len) i += 1;
            },
            ']' => { // OSC: ESC ] ... (BEL | ESC \)
                i += 2;
                while (i < s.len) {
                    if (s[i] == 0x07) {
                        i += 1;
                        break;
                    }
                    if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
            },
            '_', 'P', '^' => { // APC / DCS / PM: ESC <x> ... ESC \
                i += 2;
                while (i < s.len) {
                    if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '\\') {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
            },
            else => {
                i += 2;
            },
        }
    }
    return out.toOwnedSlice(allocator);
}
