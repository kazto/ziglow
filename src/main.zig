//! ziglow — Render markdown on the CLI, with pizzazz!
//! Zig re-implementation of charmbracelet/glow.
const std = @import("std");
const builtin = @import("builtin");
const zchomd = @import("zchomd");
const zchomptic = @import("zchomptic");
const tui = @import("tui.zig");
const mermaid = @import("mermaid.zig");
const termimage = @import("termimage.zig");
const config = @import("config.zig");

const version = "0.2.0";

const readme_names = [_][]const u8{
    "README.md", "README", "Readme.md", "Readme", "readme.md", "readme",
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var conf = try config.loadConfig(allocator);
    defer conf.deinit(allocator);

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    // --- Argument parsing ---
    var file_arg: ?[]const u8 = null;
    var style_name: []const u8 = conf.style orelse "auto";
    var width: u32 = conf.width orelse 0;
    var use_pager = if (conf.pager != null) true else false;
    var use_tui = conf.builtin_tui orelse false;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--style")) {
            i += 1;
            if (i < argv.len) style_name = argv[i];
        } else if (std.mem.startsWith(u8, arg, "--style=")) {
            style_name = arg["--style=".len..];
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--width")) {
            i += 1;
            if (i < argv.len) {
                width = std.fmt.parseInt(u32, argv[i], 10) catch 0;
            }
        } else if (std.mem.startsWith(u8, arg, "--width=")) {
            width = std.fmt.parseInt(u32, arg["--width=".len..], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pager")) {
            use_pager = true;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tui")) {
            use_tui = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            try std.fs.File.stdout().writeAll("ziglow " ++ version ++ "\n");
            return;
        } else if (std.mem.eql(u8, arg, "-")) {
            file_arg = "-";
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            file_arg = arg;
        }
    }

    // --- Terminal detection ---
    const is_terminal = std.fs.File.stdout().isTty();
    const stdin_is_pipe = !std.fs.File.stdin().isTty();

    // --- Auto-detect width ---
    if (width == 0) {
        if (is_terminal) {
            const size = zchomptic.terminal.TerminalState.getSize();
            width = @min(size.width, 120);
        }
        if (width == 0) width = 80;
    }

    // --- Effective style ---
    const effective_style: []const u8 = blk: {
        if (!is_terminal and std.mem.eql(u8, style_name, "auto")) break :blk "notty";
        if (std.mem.eql(u8, style_name, "auto")) break :blk "dark";
        break :blk style_name;
    };

    // --- Dispatch ---
    if (stdin_is_pipe and file_arg == null) {
        // Piped stdin
        const content = try std.fs.File.stdin().readToEndAlloc(allocator, 50 * 1024 * 1024);
        defer allocator.free(content);
        try processContent(allocator, content, effective_style, width, use_pager, use_tui, is_terminal, conf);
        return;
    }

    const path = file_arg orelse ".";

    if (std.mem.eql(u8, path, "-")) {
        const content = try std.fs.File.stdin().readToEndAlloc(allocator, 50 * 1024 * 1024);
        defer allocator.free(content);
        try processContent(allocator, content, effective_style, width, use_pager, use_tui, is_terminal, conf);
        return;
    }

    // Check for directory
    {
        var dir = std.fs.cwd().openDir(path, .{}) catch {
            // Not a directory — treat as file
            try processFile(allocator, path, effective_style, width, use_pager, use_tui, is_terminal, conf);
            return;
        };
        dir.close();
    }

    // Directory: find README
    const readme = try findReadme(allocator, path);
    if (readme) |rpath| {
        defer allocator.free(rpath);
        try processFile(allocator, rpath, effective_style, width, use_pager, use_tui, is_terminal, conf);
    } else {
        try std.fs.File.stderr().writeAll("ziglow: no README found\n");
        std.process.exit(1);
    }
}

/// Walk `dir_path` looking for a README file. Returns an owned path or null.
fn findReadme(allocator: std.mem.Allocator, dir_path: []const u8) !?[]u8 {
    var dir = std.fs.cwd().openDir(dir_path, .{}) catch return null;
    defer dir.close();

    for (readme_names) |name| {
        _ = dir.statFile(name) catch continue;
        return try std.fs.path.join(allocator, &.{ dir_path, name });
    }
    return null;
}

/// Open and render a markdown file.
fn processFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    style_name: []const u8,
    word_wrap: u32,
    use_pager: bool,
    use_tui: bool,
    is_terminal: bool,
    conf: config.Config,
) !void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "ziglow: cannot open '{s}': {}\n", .{ path, err });
        defer allocator.free(msg);
        try std.fs.File.stderr().writeAll(msg);
        std.process.exit(1);
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 50 * 1024 * 1024);
    defer allocator.free(content);

    try processContent(allocator, content, style_name, word_wrap, use_pager, use_tui, is_terminal, conf);
}

/// Render `content` as Markdown and output it.
/// `is_terminal`: whether stdout is a TTY (controls style + image support).
fn processContent(
    allocator: std.mem.Allocator,
    content: []const u8,
    style_name: []const u8,
    word_wrap: u32,
    use_pager: bool,
    use_tui: bool,
    is_terminal: bool,
    conf: config.Config,
) !void {
    var style_cfg = zchomd.style.getStandardStyle(style_name) orelse zchomd.style.dark;
    config.applyConfigToStyle(conf, &style_cfg);

    const img_format = termimage.detect(is_terminal, std.fs.File.stdin().isTty());
    const use_kitty_text_sizing = (img_format == .kitty);

    var tr = zchomd.TermRenderer.init(allocator, .{
        .styles = style_cfg,
        .word_wrap = @intCast(word_wrap),
        .use_kitty_text_sizing = use_kitty_text_sizing,
    });

    const rendered: []u8 = blk: {
        const has_mermaid = std.mem.indexOf(u8, content, "```mermaid") != null;

        if (is_terminal) {
            if (has_mermaid) {
                if (img_format != .none) {
                    if (try mermaid.findMmdc(allocator)) |mmdc| {
                        defer allocator.free(mmdc);

                        // ── Full pipeline: extract → render diagrams → render MD → inject ──
                        var result = try mermaid.extract(allocator, content, true);
                        defer result.deinit(allocator);

                        if (result.blocks.len > 0) {
                            const pngs = try mermaid.renderPNGs(allocator, result.blocks, mmdc);
                            defer {
                                for (pngs) |p| if (p) |bytes| allocator.free(bytes);
                                allocator.free(pngs);
                            }

                            const md_rendered = try tr.renderAlloc(result.markdown);
                            defer allocator.free(md_rendered);

                            const pngs_const: []const ?[]u8 = pngs;
                            const markers_const: []const []const u8 = result.markers;

                            break :blk try termimage.replaceMarkers(
                                allocator,
                                md_rendered,
                                markers_const,
                                pngs_const,
                                img_format,
                                word_wrap,
                            );
                        }
                    }
                }
            }
            // TTY fallback: render original content (shows mermaid as code block).
            break :blk try tr.renderAlloc(content);
        } else {
            // Piped output: replace mermaid blocks with placeholder text.
            if (has_mermaid) {
                var result = try mermaid.extract(allocator, content, false);
                defer result.deinit(allocator);
                break :blk try tr.renderAlloc(result.markdown);
            } else {
                break :blk try tr.renderAlloc(content);
            }
        }
    };
    defer allocator.free(rendered);

    if (use_tui) {
        try tui.runPager(allocator, rendered);
    } else if (use_pager) {
        const default_pager = if (builtin.os.tag == .windows) "more" else "less -R";
        const pager_cmd = conf.pager orelse termimage.getEnv("PAGER") orelse default_pager;
        try runExternalPager(allocator, rendered, pager_cmd);
    } else {
        try std.fs.File.stdout().writeAll(rendered);
    }
}

/// Pipe `content` through the external pager ($PAGER or "less -R").
fn runExternalPager(allocator: std.mem.Allocator, content: []const u8, pager_cmd: []const u8) !void {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    var it = std.mem.tokenizeScalar(u8, pager_cmd, ' ');
    while (it.next()) |part| try parts.append(allocator, part);

    if (parts.items.len == 0) {
        try std.fs.File.stdout().writeAll(content);
        return;
    }

    var child = std.process.Child.init(parts.items, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    if (child.stdin) |stdin| {
        // Write all content; ignore BrokenPipe (user may have quit pager early)
        stdin.writeAll(content) catch |err| switch (err) {
            error.BrokenPipe => {},
            else => return err,
        };
        stdin.close();
        child.stdin = null;
    }

    _ = try child.wait();
}

fn printHelp() void {
    const help =
        \\ziglow - Render markdown on the CLI, with pizzazz!
        \\
        \\Usage: ziglow [OPTIONS] [FILE|DIR|-]
        \\
        \\Arguments:
        \\  FILE        Markdown file to render
        \\  DIR         Directory (searches for README.md)
        \\  -           Read from stdin
        \\  (none)      Stdin if piped, otherwise current directory
        \\
        \\Options:
        \\  -s, --style <name>    Style: dark, light, notty, auto  [default: auto]
        \\  -w, --width <n>       Word-wrap width (0 = terminal width, max 120)
        \\  -p, --pager           Pipe output through $PAGER (default: less -R)
        \\  -t, --tui             Built-in TUI pager (j/k scroll, q quit)
        \\  -h, --help            Show this help
        \\  -V, --version         Show version
        \\
        \\Mermaid diagrams:
        \\  Requires mmdc (Mermaid CLI) in PATH.  Install with:
        \\    npm install -g @mermaid-js/mermaid-cli
        \\  Diagrams are rendered to images when the terminal supports it
        \\  (iTerm2, Kitty, WezTerm, foot, mlterm, ...).
        \\  Set ZIGLOW_SIXEL=1 to force Sixel output (requires img2sixel or convert).
        \\
    ;
    std.fs.File.stdout().writeAll(help) catch {};
}
