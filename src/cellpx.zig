//! Query the host terminal for its cell pixel size.
//!
//! Echoes (and most VTE-style terminals) answer the XTWINOPS reports:
//!   CSI 14 t  -> CSI 4 ; <text-area-height-px> ; <text-area-width-px> t
//!   CSI 18 t  -> CSI 8 ; <rows> ; <cols> t
//! Dividing the pixel area by the character area yields the per-cell pixel
//! size, which the image path needs to lay out an inline image at the same
//! number of rows the terminal will actually draw (so following content is
//! not overdrawn). Returns null if the terminal doesn't answer in time.

const std = @import("std");
const builtin = @import("builtin");
const zchomptic = @import("zchomptic");
const compat = @import("compat.zig");

pub const CellPx = struct { w: f64, h: f64 };

const is_windows = builtin.os.tag == .windows;

/// Round-trip CSI 14t / 18t against the terminal. `out_w`/`out_h` are the
/// text-area pixel size; `cols`/`rows` the character grid. Caller computes
/// the per-cell size. Returns null on any failure / timeout.
pub fn query(io: std.Io) ?CellPx {
    // Raw mode so the reply bytes are not line-buffered or echoed.
    const term = zchomptic.terminal.TerminalState.init(io) catch return null;
    defer term.deinit();

    // Ask for the pixel size and the character size.
    compat.stdoutWriteAll(io, "\x1b[14t\x1b[18t") catch return null;

    var buf: [256]u8 = undefined;
    var len: usize = 0;
    const deadline_ms: i64 = 400;
    const start = compat.milliTimestamp(io);

    var px_w: ?u32 = null;
    var px_h: ?u32 = null;
    var ch_cols: ?u32 = null;
    var ch_rows: ?u32 = null;

    while (compat.milliTimestamp(io) - start < deadline_ms) {
        const remaining: u32 = @intCast(@max(1, deadline_ms - (compat.milliTimestamp(io) - start)));
        const n = readWithTimeout(buf[len..], remaining) orelse 0;
        if (n > 0) {
            len += n;
            parseReports(buf[0..len], &px_h, &px_w, &ch_rows, &ch_cols);
            if (px_w != null and px_h != null and ch_cols != null and ch_rows != null) break;
            if (len >= buf.len) break;
        }
    }

    const pw = px_w orelse return null;
    const ph = px_h orelse return null;
    const cols = ch_cols orelse return null;
    const rows = ch_rows orelse return null;
    if (cols == 0 or rows == 0 or pw == 0 or ph == 0) return null;

    return .{
        .w = @as(f64, @floatFromInt(pw)) / @as(f64, @floatFromInt(cols)),
        .h = @as(f64, @floatFromInt(ph)) / @as(f64, @floatFromInt(rows)),
    };
}

/// Scan `data` for the two XTWINOPS replies and fill any fields found.
/// CSI 4 ; H ; W t  and  CSI 8 ; rows ; cols t.
fn parseReports(data: []const u8, ph: *?u32, pw: *?u32, rows: *?u32, cols: *?u32) void {
    var i: usize = 0;
    while (i + 2 < data.len) : (i += 1) {
        if (data[i] != 0x1b or data[i + 1] != '[') continue;
        const params_start = i + 2;
        // Find the terminating 't'.
        var j = params_start;
        while (j < data.len and data[j] != 't' and j - params_start < 32) : (j += 1) {}
        if (j >= data.len or data[j] != 't') continue;
        var a: u32 = 0;
        var b: u32 = 0;
        var c: u32 = 0;
        const kind = parseThree(data[params_start..j], &a, &b, &c);
        if (!kind) continue;
        switch (a) {
            4 => {
                ph.* = b;
                pw.* = c;
            },
            8 => {
                rows.* = b;
                cols.* = c;
            },
            else => {},
        }
        i = j;
    }
}

/// Parse "n1;n2;n3" into a,b,c. Returns false if it isn't three numbers.
fn parseThree(s: []const u8, a: *u32, b: *u32, c: *u32) bool {
    var it = std.mem.splitScalar(u8, s, ';');
    const s0 = it.next() orelse return false;
    const s1 = it.next() orelse return false;
    const s2 = it.next() orelse return false;
    if (it.next() != null) return false;
    a.* = std.fmt.parseInt(u32, std.mem.trim(u8, s0, " "), 10) catch return false;
    b.* = std.fmt.parseInt(u32, std.mem.trim(u8, s1, " "), 10) catch return false;
    c.* = std.fmt.parseInt(u32, std.mem.trim(u8, s2, " "), 10) catch return false;
    return true;
}

/// Read up to dst.len bytes, waiting at most timeout_ms. Returns bytes read
/// (0 on timeout), or null on error.
fn readWithTimeout(dst: []u8, timeout_ms: u32) ?usize {
    if (dst.len == 0) return 0;
    if (is_windows) {
        const w = std.os.windows;
        const h = w.kernel32.GetStdHandle(w.STD_INPUT_HANDLE) orelse return null;
        const WAIT_OBJECT_0: w.DWORD = 0;
        const wait = w.kernel32.WaitForSingleObject(h, timeout_ms);
        if (wait != WAIT_OBJECT_0) return 0;
        var read: w.DWORD = 0;
        const ok = w.kernel32.ReadFile(h, dst.ptr, @intCast(dst.len), &read, null);
        if (ok == 0) return null;
        return @intCast(read);
    }
    const posix = std.posix;
    var pfd = [_]posix.pollfd{.{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 }};
    const ready = posix.poll(&pfd, @intCast(timeout_ms)) catch return null;
    if (ready == 0) return 0;
    const n = posix.read(posix.STDIN_FILENO, dst) catch return null;
    return n;
}
