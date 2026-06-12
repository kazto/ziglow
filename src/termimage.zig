//! Terminal image format detection and encoding.
//! Supports iTerm2 inline images, Kitty graphics protocol, and Sixel graphics.
const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");

pub const Format = enum { none, iterm2, kitty, sixel };

/// Look up an environment variable. Caller owns the returned slice and must
/// free it with `allocator`. Returns null if unset (or on OOM / bad encoding).
pub fn getEnv(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, name: []const u8) ?[]u8 {
    const value = env.get(name) orelse return null;
    return allocator.dupe(u8, value) catch null;
}

/// True when env var `name` is set and exactly equals `expected`.
fn envEquals(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, name: []const u8, expected: []const u8) bool {
    const v = getEnv(allocator, env, name) orelse return false;
    defer allocator.free(v);
    return std.mem.eql(u8, v, expected);
}

/// True when env var `name` is set and contains `needle`.
fn envContains(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, name: []const u8, needle: []const u8) bool {
    const v = getEnv(allocator, env, name) orelse return false;
    defer allocator.free(v);
    return std.mem.indexOf(u8, v, needle) != null;
}

/// True when env var `name` is set (to any value).
fn envExists(allocator: std.mem.Allocator, env: *const std.process.Environ.Map, name: []const u8) bool {
    const v = getEnv(allocator, env, name) orelse return false;
    allocator.free(v);
    return true;
}

/// Detect the terminal's inline image capability.
/// Pass whether stdout and stdin are TTYs.
pub fn detect(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, stdout_is_tty: bool, stdin_is_tty: bool) Format {
    if (!stdout_is_tty) return .none;

    // Explicit override.
    if (envEquals(allocator, env, "ZIGLOW_SIXEL", "1")) return .sixel;
    if (envEquals(allocator, env, "GLOWM_SIXEL", "1")) return .sixel;

    // Echoes advertises which inline image protocol the host wants via
    // ECHOES_INLINE_IMAGE_PROTOCOL. On Windows it requests "osc1337" because the
    // ConPTY layer reconstructs the screen grid and discards Kitty graphics APC
    // frames, while iTerm2 OSC 1337 inline images pass through untouched. Honor
    // it before the generic Echoes→Kitty detection below.
    if (echoesImageFormat(allocator, env)) |fmt| return fmt;

    if (isIterm2(allocator, env)) return .iterm2;
    if (stdin_is_tty) {
        if (queryKittyGraphics(io)) |supported| {
            if (supported) return .kitty;
        } else if (isKitty(allocator, env)) {
            return .kitty;
        }
    } else if (isKitty(allocator, env)) return .kitty;
    if (isKnownSixelTerminal(allocator, env)) return .sixel;

    // Query terminal via DA1 (Device Attributes) if stdin is available.
    // (querySixelViaDA1 is a no-op on Windows.)
    if (stdin_is_tty and querySixelViaDA1(io)) return .sixel;

    return .none;
}

/// Detect whether the terminal supports Kitty Text Sizing Protocol (OSC 66).
/// This is intentionally independent from inline graphics detection: Echoes on
/// Windows can use iTerm2 OSC 1337 for graphics while still supporting OSC 66.
pub fn detectTextSizing(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, stdout_is_tty: bool, stdin_is_tty: bool) bool {
    if (!stdout_is_tty) return false;
    if (stdin_is_tty) {
        if (queryTextSizing(io)) |supported| return supported;
    }

    const term_program = getEnv(allocator, env, "TERM_PROGRAM");
    defer if (term_program) |v| allocator.free(v);
    const term = getEnv(allocator, env, "TERM");
    defer if (term) |v| allocator.free(v);

    return textSizingForEnv(
        term_program,
        term,
        envExists(allocator, env, "KITTY_WINDOW_ID"),
    );
}

fn isIterm2(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) bool {
    return envEquals(allocator, env, "TERM_PROGRAM", "iTerm.app");
}

fn isKitty(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) bool {
    if (envExists(allocator, env, "KITTY_WINDOW_ID")) return true;
    if (getEnv(allocator, env, "TERM_PROGRAM")) |term_program| {
        defer allocator.free(term_program);
        if (isEchoesTermProgram(term_program)) return true;
    }
    return envContains(allocator, env, "TERM", "xterm-kitty");
}

fn isEchoesTermProgram(term_program: []const u8) bool {
    return std.mem.eql(u8, term_program, "Echoes");
}

test "TERM_PROGRAM Echoes enables Kitty-compatible handling" {
    try std.testing.expect(isEchoesTermProgram("Echoes"));
}

/// Map the value Echoes advertises in ECHOES_INLINE_IMAGE_PROTOCOL to a
/// `Format`. "osc1337" → iTerm2 OSC 1337 (used on Windows, survives ConPTY),
/// "kitty" → Kitty graphics. Returns null for an unset/unknown value so the
/// caller falls back to its normal terminal detection.
fn imageFormatForEchoesProtocol(protocol: []const u8) ?Format {
    if (std.mem.eql(u8, protocol, "osc1337")) return .iterm2;
    if (std.mem.eql(u8, protocol, "kitty")) return .kitty;
    return null;
}

/// Read ECHOES_INLINE_IMAGE_PROTOCOL and resolve it to a `Format`, or null if
/// unset/unknown.
fn echoesImageFormat(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ?Format {
    const v = getEnv(allocator, env, "ECHOES_INLINE_IMAGE_PROTOCOL") orelse return null;
    defer allocator.free(v);
    return imageFormatForEchoesProtocol(v);
}

test "ECHOES_INLINE_IMAGE_PROTOCOL selects image format" {
    try std.testing.expectEqual(@as(?Format, .iterm2), imageFormatForEchoesProtocol("osc1337"));
    try std.testing.expectEqual(@as(?Format, .kitty), imageFormatForEchoesProtocol("kitty"));
    try std.testing.expectEqual(@as(?Format, null), imageFormatForEchoesProtocol(""));
    try std.testing.expectEqual(@as(?Format, null), imageFormatForEchoesProtocol("sixel"));
}

fn textSizingForEnv(term_program: ?[]const u8, term: ?[]const u8, kitty_window_id_exists: bool) bool {
    if (kitty_window_id_exists) return true;
    if (term_program) |tp| {
        if (isEchoesTermProgram(tp)) return true;
    }
    if (term) |t| {
        if (std.mem.indexOf(u8, t, "xterm-kitty") != null) return true;
    }
    return false;
}

test "Echoes OSC 1337 graphics still supports Kitty text sizing" {
    try std.testing.expect(textSizingForEnv("Echoes", "xterm-256color", false));
}

fn isKnownSixelTerminal(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) bool {
    if (envEquals(allocator, env, "TERM_PROGRAM", "WezTerm")) return true;
    const term = getEnv(allocator, env, "TERM") orelse return false;
    defer allocator.free(term);
    const known = [_][]const u8{ "mlterm", "yaft-256color", "foot", "foot-direct", "contour" };
    for (known) |name| if (std.mem.eql(u8, term, name)) return true;
    return false;
}

fn withRawTerminal(comptime func: fn (std.Io) ?bool, io: std.Io) ?bool {
    if (builtin.os.tag == .windows) return null;

    const stdin_handle = std.posix.STDIN_FILENO;
    const termios = std.posix.tcgetattr(stdin_handle) catch return null;
    var raw = termios;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.cc[@intFromEnum(std.posix.system.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.system.V.TIME)] = 2;

    std.posix.tcsetattr(stdin_handle, .FLUSH, raw) catch return null;
    defer std.posix.tcsetattr(stdin_handle, .FLUSH, termios) catch {};

    return func(io);
}

fn readProbeResponse(io: std.Io, query: []const u8, buf: []u8) usize {
    compat.stdoutWriteAll(io, query) catch return 0;

    var total: usize = 0;
    while (total < buf.len) {
        const n = std.posix.read(std.posix.STDIN_FILENO, buf[total..]) catch return total;
        if (n == 0) break;
        total += n;
    }
    return total;
}

fn queryKittyGraphics(io: std.Io) ?bool {
    return withRawTerminal(queryKittyGraphicsRaw, io);
}

fn queryKittyGraphicsRaw(io: std.Io) ?bool {
    var buf: [512]u8 = undefined;
    const n = readProbeResponse(
        io,
        "\x1b_Gi=424242,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[c",
        &buf,
    );
    if (n == 0) return null;
    if (parseKittyGraphicsResponse(buf[0..n], 424242)) return true;
    if (parseDeviceAttributesResponse(buf[0..n])) return false;
    return null;
}

fn parseKittyGraphicsResponse(resp: []const u8, id: u32) bool {
    var needle_buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\x1b_Gi={d};", .{id}) catch return false;
    return std.mem.indexOf(u8, resp, needle) != null;
}

test "parse Kitty graphics query response" {
    try std.testing.expect(parseKittyGraphicsResponse("\x1b_Gi=424242;OK\x1b\\", 424242));
    try std.testing.expect(parseKittyGraphicsResponse("\x1b_Gi=424242;EINVAL:bad data\x1b\\", 424242));
    try std.testing.expect(!parseKittyGraphicsResponse("\x1b[?62;4c", 424242));
    try std.testing.expect(!parseKittyGraphicsResponse("\x1b_Gi=7;OK\x1b\\", 424242));
}

fn queryTextSizing(io: std.Io) ?bool {
    return withRawTerminal(queryTextSizingRaw, io);
}

fn queryTextSizingRaw(io: std.Io) ?bool {
    var buf: [512]u8 = undefined;
    const n = readProbeResponse(
        io,
        "\x1b7\r\x1b[6n\x1b]66;w=2; \x07\x1b[6n\x1b]66;s=2; \x07\x1b[6n\x1b8",
        &buf,
    );
    if (n == 0) return null;

    var reports: [3]CursorPosition = undefined;
    const count = parseCursorPositionReports(buf[0..n], &reports);
    if (count < 3) return null;

    const first = reports[0];
    const second = reports[1];
    const third = reports[2];
    if (second.row != first.row or third.row != second.row) return false;
    if (second.col < first.col + 2) return false;
    if (third.col < second.col + 2) return false;
    return true;
}

const CursorPosition = struct {
    row: u32,
    col: u32,
};

fn parseCursorPositionReports(resp: []const u8, out: *[3]CursorPosition) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < resp.len and count < out.len) : (i += 1) {
        if (resp[i] != 0x1b or i + 2 >= resp.len or resp[i + 1] != '[') continue;
        var j = i + 2;
        const row_start = j;
        while (j < resp.len and std.ascii.isDigit(resp[j])) : (j += 1) {}
        if (j == row_start or j >= resp.len or resp[j] != ';') continue;
        const row = std.fmt.parseInt(u32, resp[row_start..j], 10) catch continue;
        j += 1;
        const col_start = j;
        while (j < resp.len and std.ascii.isDigit(resp[j])) : (j += 1) {}
        if (j == col_start or j >= resp.len or resp[j] != 'R') continue;
        const col = std.fmt.parseInt(u32, resp[col_start..j], 10) catch continue;
        out[count] = .{ .row = row, .col = col };
        count += 1;
        i = j;
    }
    return count;
}

test "parse cursor position reports" {
    var reports: [3]CursorPosition = undefined;
    const count = parseCursorPositionReports("noise\x1b[12;1R\x1b[12;3R\x1b[12;5R", &reports);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(CursorPosition{ .row = 12, .col = 1 }, reports[0]);
    try std.testing.expectEqual(CursorPosition{ .row = 12, .col = 3 }, reports[1]);
    try std.testing.expectEqual(CursorPosition{ .row = 12, .col = 5 }, reports[2]);
}

/// Query the terminal via DA1 (Primary Device Attributes) to check for Sixel support.
fn querySixelViaDA1(io: std.Io) bool {
    return withRawTerminal(querySixelViaDA1Raw, io) orelse false;
}

fn parseDeviceAttributesResponse(resp: []const u8) bool {
    var i: usize = 0;
    while (i < resp.len) : (i += 1) {
        if (resp[i] != 0x1b or i + 2 >= resp.len or resp[i + 1] != '[') continue;
        var j = i + 2;
        if (j < resp.len and resp[j] == '?') j += 1;
        const param_start = j;
        while (j < resp.len and (std.ascii.isDigit(resp[j]) or resp[j] == ';')) : (j += 1) {}
        if (j > param_start and j < resp.len and resp[j] == 'c') return true;
    }
    return false;
}

test "parse DA1 response presence" {
    try std.testing.expect(parseDeviceAttributesResponse("\x1b[?62;4c"));
    try std.testing.expect(parseDeviceAttributesResponse("x\x1b[?1;2c"));
    try std.testing.expect(!parseDeviceAttributesResponse("\x1b[12;5R"));
}

fn querySixelViaDA1Raw(io: std.Io) ?bool {
    var buf: [64]u8 = undefined;
    const n = readProbeResponse(io, "\x1b[c", &buf);
    if (n == 0) return null;
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
/// `width_cells` / `height_cells` size the image in character cells (0 = let
/// the terminal pick that dimension from the image's natural pixel size).
/// Returns an owned string, or null for Format.none / encoding failure.
pub fn encode(
    allocator: std.mem.Allocator,
    io: std.Io,
    format: Format,
    png: []const u8,
    width_cells: u32,
    height_cells: u32,
) !?[]u8 {
    return switch (format) {
        .none => null,
        .iterm2 => try encodeIterm2(allocator, png, width_cells, height_cells),
        .kitty => try encodeKitty(allocator, png, width_cells, height_cells),
        .sixel => try encodeSixel(allocator, io, png),
    };
}

fn encodeIterm2(allocator: std.mem.Allocator, png: []const u8, width_cells: u32, height_cells: u32) !?[]u8 {
    const Enc = std.base64.standard.Encoder;
    const b64_len = Enc.calcSize(png.len);
    const b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64);
    _ = Enc.encode(b64, png);

    // Build the optional ";width=W;height=H" fragment. Both are given together
    // so the cell box matches what ziglow reserved in the text flow, keeping
    // following content from being overdrawn.
    const dims: []u8 = if (width_cells > 0 and height_cells > 0)
        try std.fmt.allocPrint(allocator, ";width={d};height={d}", .{ width_cells, height_cells })
    else if (width_cells > 0)
        try std.fmt.allocPrint(allocator, ";width={d}", .{width_cells})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(dims);

    return @as(?[]u8, try std.fmt.allocPrint(
        allocator,
        "\x1b]1337;File=inline=1;preserveAspectRatio=1{s}:{s}\x07\n",
        .{ dims, b64 },
    ));
}

fn encodeKitty(allocator: std.mem.Allocator, png: []const u8, width_cells: u32, height_cells: u32) !?[]u8 {
    const Enc = std.base64.standard.Encoder;
    const b64_len = Enc.calcSize(png.len);
    const b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64);
    _ = Enc.encode(b64, png);

    // Kitty sizes a placement with c= (columns) and r= (rows).
    const dims: []u8 = if (width_cells > 0 and height_cells > 0)
        try std.fmt.allocPrint(allocator, ",c={d},r={d}", .{ width_cells, height_cells })
    else if (width_cells > 0)
        try std.fmt.allocPrint(allocator, ",c={d}", .{width_cells})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(dims);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const chunk = 4096;
    var i: usize = 0;
    while (i < b64.len) {
        const end = @min(i + chunk, b64.len);
        const more: u8 = if (end < b64.len) '1' else '0';
        const header = if (i == 0)
            try std.fmt.allocPrint(allocator, "\x1b_Gf=100,a=T{s},m={c};", .{ dims, more })
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
fn encodeSixel(allocator: std.mem.Allocator, io: std.Io, png: []const u8) !?[]u8 {
    if (builtin.os.tag == .windows) return null;

    const ts: u64 = @bitCast(compat.milliTimestamp(io));
    const tmp = try std.fmt.allocPrint(allocator, "/tmp/ziglow_six_{x}.png", .{ts});
    defer allocator.free(tmp);
    defer compat.cwdDeleteFile(io, tmp) catch {};

    {
        const f = compat.cwdCreateFile(io, tmp, .{}) catch return null;
        defer f.close(io);
        compat.writeFileAll(io, f, png) catch return null;
    }

    // Try img2sixel first, then ImageMagick convert.
    const cmds = [_][]const []const u8{
        &.{ "img2sixel", tmp },
        &.{ "convert", tmp, "sixel:-" },
    };
    for (cmds) |argv| {
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch continue;

        const output: ?[]u8 = if (child.stdout) |stdout|
            compat.readFileAlloc(io, stdout, allocator, 10 * 1024 * 1024) catch blk: {
                _ = child.wait(io) catch {};
                break :blk null;
            }
        else
            null;

        _ = child.wait(io) catch {};

        if (output) |o| {
            if (o.len > 0) return o;
            allocator.free(o);
        }
    }
    return null;
}

// ── Marker replacement ────────────────────────────────────────────────────────

/// Replace marker lines in `output` with caller-supplied strings.
/// `markers` and `replacements` are parallel slices. A null replacement keeps
/// the original line; a non-null replacement (including "") is substituted for
/// the whole line — "" is used for image-block spacer markers, which only exist
/// to reserve vertical rows in the text flow. Returns an owned string.
pub fn replaceMarkers(
    allocator: std.mem.Allocator,
    output: []const u8,
    markers: []const []const u8,
    replacements: []const ?[]const u8,
) ![]u8 {
    if (markers.len == 0) return allocator.dupe(u8, output);

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
                const rep: ?[]const u8 = if (i < replacements.len) replacements[i] else null;
                if (rep) |s| {
                    try result.appendSlice(allocator, s);
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
