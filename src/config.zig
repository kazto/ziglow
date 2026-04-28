const std = @import("std");
const zchomd = @import("zchomd");

pub const Config = struct {
    h1_foreground: ?[]const u8 = null,
    h1_background: ?[]const u8 = null,
    h1_scale: ?f32 = null,
    h2_foreground: ?[]const u8 = null,
    h2_background: ?[]const u8 = null,
    h2_scale: ?f32 = null,
    style: ?[]const u8 = null,
    width: ?u32 = null,
    pager: ?[]const u8 = null,
    builtin_tui: ?bool = null,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.h1_foreground) |v| allocator.free(v);
        if (self.h1_background) |v| allocator.free(v);
        if (self.h2_foreground) |v| allocator.free(v);
        if (self.h2_background) |v| allocator.free(v);
        if (self.style) |v| allocator.free(v);
        if (self.pager) |v| allocator.free(v);
    }
};

pub fn loadConfig(allocator: std.mem.Allocator) !Config {
    var conf = Config{};

    const home = std.posix.getenv("HOME") orelse return conf;
    const xdg_config_home = std.posix.getenv("XDG_CONFIG_HOME");

    var path_buf: [1024]u8 = undefined;
    const config_path = if (xdg_config_home) |xdg|
        try std.fmt.bufPrint(&path_buf, "{s}/ziglow/ziglow.toml", .{xdg})
    else
        try std.fmt.bufPrint(&path_buf, "{s}/.config/ziglow/ziglow.toml", .{home});

    const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| {
        if (err == error.FileNotFound) return conf;
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    try parseConfig(allocator, &conf, content);

    return conf;
}

pub fn parseConfig(allocator: std.mem.Allocator, conf: *Config, content: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, content, "\r\n");
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        var kv_it = std.mem.splitScalar(u8, trimmed, '=');
        const key = std.mem.trim(u8, kv_it.next() orelse continue, " \t");
        const val_raw = std.mem.trim(u8, kv_it.rest(), " \t");

        if (std.mem.eql(u8, key, "h1_foreground")) {
            conf.h1_foreground = try parseString(allocator, val_raw);
        } else if (std.mem.eql(u8, key, "h1_background")) {
            conf.h1_background = try parseString(allocator, val_raw);
        } else if (std.mem.eql(u8, key, "h1_scale")) {
            conf.h1_scale = std.fmt.parseFloat(f32, val_raw) catch null;
        } else if (std.mem.eql(u8, key, "h2_foreground")) {
            conf.h2_foreground = try parseString(allocator, val_raw);
        } else if (std.mem.eql(u8, key, "h2_background")) {
            conf.h2_background = try parseString(allocator, val_raw);
        } else if (std.mem.eql(u8, key, "h2_scale")) {
            conf.h2_scale = std.fmt.parseFloat(f32, val_raw) catch null;
        } else if (std.mem.eql(u8, key, "style")) {
            conf.style = try parseString(allocator, val_raw);
        } else if (std.mem.eql(u8, key, "width")) {
            conf.width = std.fmt.parseInt(u32, val_raw, 10) catch null;
        } else if (std.mem.eql(u8, key, "pager")) {
            conf.pager = try parseString(allocator, val_raw);
        } else if (std.mem.eql(u8, key, "builtin_tui")) {
            conf.builtin_tui = std.mem.eql(u8, val_raw, "true");
        }
    }
}

fn parseString(allocator: std.mem.Allocator, raw: []const u8) !?[]u8 {
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
        return try allocator.dupe(u8, raw[1 .. raw.len - 1]);
    }
    if (raw.len >= 2 and raw[0] == '\'' and raw[raw.len - 1] == '\'') {
        return try allocator.dupe(u8, raw[1 .. raw.len - 1]);
    }
    if (raw.len == 0) return null;
    return try allocator.dupe(u8, raw);
}

pub fn applyConfigToStyle(conf: Config, style_cfg: *zchomd.style.StyleConfig) void {
    if (conf.h1_foreground) |v| style_cfg.h1.style.color = v;
    if (conf.h1_background) |v| style_cfg.h1.style.background_color = v;
    if (conf.h1_scale) |v| style_cfg.h1.scale = v;

    if (conf.h2_foreground) |v| style_cfg.h2.style.color = v;
    if (conf.h2_background) |v| style_cfg.h2.style.background_color = v;
    if (conf.h2_scale) |v| style_cfg.h2.scale = v;
}

test "parse toml" {
    const allocator = std.testing.allocator;
    const content =
        \\h1_foreground = "#1f1f1f"
        \\h1_background = "#a0a0a0"
        \\h1_scale = 3.5
        \\style = dark
        \\width = 100
        \\pager = "less -R"
        \\builtin_tui = true
    ;

    var conf = Config{};
    defer conf.deinit(allocator);

    try parseConfig(allocator, &conf, content);

    try std.testing.expectEqualStrings("#1f1f1f", conf.h1_foreground.?);
    try std.testing.expectEqualStrings("#a0a0a0", conf.h1_background.?);
    try std.testing.expectEqual(@as(f32, 3.5), conf.h1_scale.?);
    try std.testing.expectEqualStrings("dark", conf.style.?);
    try std.testing.expectEqual(@as(u32, 100), conf.width.?);
    try std.testing.expectEqualStrings("less -R", conf.pager.?);
    try std.testing.expectEqual(true, conf.builtin_tui.?);
}
