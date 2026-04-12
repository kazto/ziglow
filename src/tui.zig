//! TUI pager for ziglow — scrollable markdown viewer using zchomptic.
const std = @import("std");
const zchomptic = @import("zchomptic");

/// Scrollable pager model.
pub const Pager = struct {
    /// Lines of the rendered content (slices into the rendered buffer).
    lines: std.ArrayList([]const u8),
    /// Allocator used for the lines list.
    allocator: std.mem.Allocator,
    /// Current scroll offset (line index of topmost visible line).
    offset: usize,
    /// Visible height in lines (terminal rows minus status bar).
    height: usize,

    pub fn init(self: *Pager) ?zchomptic.Cmd {
        _ = self;
        return null;
    }

    pub fn update(self: *Pager, m: zchomptic.Msg) ?zchomptic.Cmd {
        switch (m) {
            .key_press => |k| switch (k.key) {
                .char => |c| switch (c) {
                    'q', 'Q' => return zchomptic.cmd.quit,
                    'j' => self.scrollDown(1),
                    'k' => self.scrollUp(1),
                    'd' => self.scrollDown(self.height / 2),
                    'u' => self.scrollUp(self.height / 2),
                    'f' => self.scrollDown(self.height),
                    'b' => self.scrollUp(self.height),
                    ' ' => self.scrollDown(self.height),
                    'g' => self.offset = 0,
                    'G' => self.scrollToEnd(),
                    else => {},
                },
                .code => |code| switch (code) {
                    .down => self.scrollDown(1),
                    .up => self.scrollUp(1),
                    .page_down => self.scrollDown(self.height),
                    .page_up => self.scrollUp(self.height),
                    .home => self.offset = 0,
                    .end => self.scrollToEnd(),
                    else => {},
                },
                .ctrl => |c| switch (c) {
                    3 => return zchomptic.cmd.quit, // Ctrl+C
                    4 => self.scrollDown(self.height / 2), // Ctrl+D
                    21 => self.scrollUp(self.height / 2), // Ctrl+U
                    6 => self.scrollDown(self.height), // Ctrl+F
                    2 => self.scrollUp(self.height), // Ctrl+B
                    else => {},
                },
            },
            .interrupt => return zchomptic.cmd.quit,
            else => {},
        }
        return null;
    }

    pub fn view(self: *Pager, writer: std.io.AnyWriter) !void {
        const total = self.lines.items.len;
        const end = @min(self.offset + self.height, total);
        for (self.lines.items[self.offset..end]) |line| {
            try writer.print("{s}\n", .{line});
        }
        // Status bar
        const bottom = @min(self.offset + self.height, total);
        const pct: u32 = if (total == 0) 100 else @intCast(@min(100, bottom * 100 / total));
        try writer.print(
            "-- {d}/{d} ({d}%) -- j/k:scroll  d/u:half-page  g/G:top/bottom  q:quit",
            .{ bottom, total, pct },
        );
    }

    fn scrollDown(self: *Pager, n: usize) void {
        const total = self.lines.items.len;
        const max = if (total > self.height) total - self.height else 0;
        self.offset = @min(self.offset + n, max);
    }

    fn scrollUp(self: *Pager, n: usize) void {
        self.offset = if (self.offset >= n) self.offset - n else 0;
    }

    fn scrollToEnd(self: *Pager) void {
        const total = self.lines.items.len;
        if (total > self.height) {
            self.offset = total - self.height;
        }
    }
};

/// Run the TUI pager displaying `content` (pre-rendered ANSI text).
pub fn runPager(allocator: std.mem.Allocator, content: []const u8) !void {
    const sz = zchomptic.terminal.TerminalState.getSize();
    const height: usize = if (sz.height > 2) @as(usize, sz.height) - 1 else 10;

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);

    // Split rendered content into lines (slices point into `content`).
    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        try lines.append(allocator, line);
    }
    // Trim trailing blank lines.
    while (lines.items.len > 0 and lines.getLast().len == 0) {
        _ = lines.pop();
    }

    var pager = Pager{
        .lines = lines,
        .allocator = allocator,
        .offset = 0,
        .height = height,
    };

    var prog = zchomptic.Program.init(allocator, zchomptic.model(&pager));
    defer prog.deinit();
    try prog.run();
}
