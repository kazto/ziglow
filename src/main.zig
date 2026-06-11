//! ziglow — Render markdown on the CLI, with pizzazz!
//! Zig re-implementation of charmbracelet/glow.
const std = @import("std");
const builtin = @import("builtin");
const zchomd = @import("zchomd");
const zchomptic = @import("zchomptic");
const tui = @import("tui.zig");
const mermaid = @import("mermaid.zig");
const termimage = @import("termimage.zig");
const image = @import("image.zig");
const config = @import("config.zig");
const cellpx = @import("cellpx.zig");
const compat = @import("compat.zig");

const version = "0.6.1";

const readme_names = [_][]const u8{
    "README.md", "README", "Readme.md", "Readme", "readme.md", "readme",
};
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // We emit UTF-8 (box-drawing, bullets, …). On Windows the console/ConPTY
    // otherwise decodes our bytes with the legacy OEM code page (e.g. CP932),
    // turning "•" into mojibake. Tell it our output is UTF-8. The extern and
    // call live inside this comptime-Windows branch, so nothing Windows-specific
    // is compiled on macOS/Linux.
    if (comptime builtin.os.tag == .windows) {
        const kernel32 = struct {
            extern "kernel32" fn SetConsoleOutputCP(wCodePageID: std.os.windows.UINT) callconv(.winapi) std.os.windows.BOOL;
            extern "kernel32" fn GetStdHandle(nStdHandle: std.os.windows.DWORD) callconv(.winapi) std.os.windows.HANDLE;
            extern "kernel32" fn GetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, lpMode: *std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
            extern "kernel32" fn SetConsoleMode(hConsoleHandle: std.os.windows.HANDLE, dwMode: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
        };
        const STD_OUTPUT_HANDLE: std.os.windows.DWORD = 0xfffffff5;
        const ENABLE_VIRTUAL_TERMINAL_PROCESSING: std.os.windows.DWORD = 0x0004;
        _ = kernel32.SetConsoleOutputCP(65001); // CP_UTF8
        const stdout_handle = kernel32.GetStdHandle(STD_OUTPUT_HANDLE);
        var mode: std.os.windows.DWORD = 0;
        if (kernel32.GetConsoleMode(stdout_handle, &mode) != 0) {
            _ = kernel32.SetConsoleMode(stdout_handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        }
    }

    const io = init.io;
    const env = init.environ_map;

    var conf = try config.loadConfig(allocator, io, env);
    // ...

    defer conf.deinit(allocator);

    const argv = try init.minimal.args.toSlice(init.arena.allocator());

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
            printHelp(io);
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            try compat.stdoutWriteAll(io, "ziglow " ++ version ++ "\n");
            return;
        } else if (std.mem.eql(u8, arg, "-")) {
            file_arg = "-";
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            file_arg = arg;
        }
    }

    // --- Terminal detection ---
    const is_terminal = try std.Io.File.stdout().isTty(io);
    const stdin_is_pipe = !try std.Io.File.stdin().isTty(io);

    // --- Auto-detect width ---
    if (width == 0) {
        if (is_terminal) {
            const size = zchomptic.terminal.TerminalState.getSize();
            width = @min(size.width, 120);
            if (use_tui and width > 1) width -= 1;
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
        const content = try compat.stdinReadAllAlloc(io, allocator, 50 * 1024 * 1024);
        defer allocator.free(content);
        try processContent(allocator, io, env, content, effective_style, width, use_pager, use_tui, is_terminal, null, conf);
        return;
    }

    const path = file_arg orelse ".";

    if (std.mem.eql(u8, path, "-")) {
        const content = try compat.stdinReadAllAlloc(io, allocator, 50 * 1024 * 1024);
        defer allocator.free(content);
        try processContent(allocator, io, env, content, effective_style, width, use_pager, use_tui, is_terminal, null, conf);
        return;
    }

    // Check for directory
    {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch {
            // Not a directory — treat as file
            try processFile(allocator, io, env, path, effective_style, width, use_pager, use_tui, is_terminal, conf);
            return;
        };
        dir.close(io);
    }

    // Directory: find README
    const readme = try findReadme(allocator, io, path);
    if (readme) |rpath| {
        defer allocator.free(rpath);
        try processFile(allocator, io, env, rpath, effective_style, width, use_pager, use_tui, is_terminal, conf);
    } else {
        try compat.stderrWriteAll(io, "ziglow: no README found\n");
        std.process.exit(1);
    }
}

/// Walk `dir_path` looking for a README file. Returns an owned path or null.
fn findReadme(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return null;
    defer dir.close(io);

    for (readme_names) |name| {
        _ = dir.statFile(io, name, .{}) catch continue;
        return try std.fs.path.join(allocator, &.{ dir_path, name });
    }
    return null;
}

/// Open and render a markdown file.
fn processFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    path: []const u8,
    style_name: []const u8,
    word_wrap: u32,
    use_pager: bool,
    use_tui: bool,
    is_terminal: bool,
    conf: config.Config,
) !void {
    const file = compat.cwdOpenFile(io, path, .{}) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "ziglow: cannot open '{s}': {}\n", .{ path, err });
        defer allocator.free(msg);
        try compat.stderrWriteAll(io, msg);
        std.process.exit(1);
    };
    defer file.close(io);

    const content = try compat.readFileAlloc(io, file, allocator, 50 * 1024 * 1024);
    defer allocator.free(content);

    const base_dir = std.fs.path.dirname(path);
    try processContent(allocator, io, env, content, style_name, word_wrap, use_pager, use_tui, is_terminal, base_dir, conf);
}

/// Render `content` for a TTY, substituting mermaid diagrams and standalone
/// local images with inline graphics. Merges both marker sets and calls
/// `replaceMarkers` once. Returns an owned rendered string.
fn renderTerminal(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
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
    var mermaid_pngs: []const ?[]u8 = &.{};
    var mres: ?mermaid.MermaidResult = null;
    defer if (mres) |*r| r.deinit(allocator);
    var pngs: ?[]?[]u8 = null;
    defer if (pngs) |p| {
        for (p) |x| if (x) |b| allocator.free(b);
        allocator.free(p);
    };

    var md1: []const u8 = content;
    if (has_mermaid) {
        if (try mermaid.findMmdc(allocator, io, env)) |mmdc| {
            defer allocator.free(mmdc);
            var r = try mermaid.extract(allocator, content, true);
            if (r.blocks.len > 0) {
                // Transfer ownership to `mres` BEFORE any further fallible call,
                // so the outer defer frees `r` if `renderPNGs` errors.
                mres = r;
                pngs = try mermaid.renderPNGs(allocator, io, r.blocks, mmdc);
                mermaid_pngs = pngs.?;
                mermaid_markers = r.markers;
                md1 = r.markdown;
            } else {
                r.deinit(allocator);
            }
        }
    }

    // ── Stage 2: image sizing + extraction ──
    // Ask the terminal for its cell pixel size so each image is laid out at the
    // exact cell height the terminal will draw. Without this, the image marker
    // reserves ~1 row in the text flow while the terminal paints many rows,
    // and following content (e.g. the next shell prompt) is overdrawn. Only
    // bother when the document actually contains an image candidate.
    var cell_w: f64 = 0;
    var cell_h: f64 = 0;
    if (std.mem.indexOf(u8, md1, "![") != null) {
        if (cellpx.query(io)) |c| {
            cell_w = c.w;
            cell_h = c.h;
        }
    }
    const term_rows: u32 = zchomptic.terminal.TerminalState.getSize().height;

    var img = try image.extract(allocator, io, md1, base_dir, cell_w, cell_h, word_wrap, term_rows);
    defer img.deinit(allocator);

    // ── Render the fully-substituted markdown ──
    const md_rendered = try tr.renderAlloc(img.markdown);
    defer allocator.free(md_rendered);

    // Fast path: nothing to substitute.
    if (mermaid_markers.len == 0 and img.images.len == 0) {
        return allocator.dupe(u8, md_rendered);
    }

    // ── Merge marker + replacement sets and substitute once ──
    // Owned encoded escape strings are tracked here and freed after the swap.
    var encoded: std.ArrayList([]u8) = .empty;
    defer {
        for (encoded.items) |e| allocator.free(e);
        encoded.deinit(allocator);
    }
    var all_markers: std.ArrayList([]const u8) = .empty;
    defer all_markers.deinit(allocator);
    var all_replacements: std.ArrayList(?[]const u8) = .empty;
    defer all_replacements.deinit(allocator);

    // Mermaid diagrams: natural size, single marker (no row reservation).
    for (mermaid_markers, 0..) |m, i| {
        try all_markers.append(allocator, m);
        const png = if (i < mermaid_pngs.len) mermaid_pngs[i] else null;
        var rep: ?[]const u8 = ""; // blank a failed render rather than leak the marker
        if (png) |p| {
            if (termimage.encode(allocator, io, img_format, p, 0, 0) catch null) |e| {
                try encoded.append(allocator, e);
                rep = e;
            }
        }
        try all_replacements.append(allocator, rep);
    }

    // Standalone images: the primary marker becomes the inline-image escape
    // (sized to cols×rows); spacer markers collapse to "" — their paragraphs
    // already reserved the remaining image rows in the rendered layout.
    for (img.images) |im| {
        try all_markers.append(allocator, im.primary);
        // Default to "" (blank the marker) so a missing/undecodable image
        // doesn't leak its internal "ZIGLOWIMAGEn" placeholder onto the screen.
        var rep: ?[]const u8 = "";
        if (im.bytes) |b| {
            if (termimage.encode(allocator, io, img_format, b, im.cols, im.rows) catch null) |e| {
                try encoded.append(allocator, e);
                rep = e;
            }
        }
        try all_replacements.append(allocator, rep);
        for (im.spacers) |s| {
            try all_markers.append(allocator, s);
            try all_replacements.append(allocator, @as(?[]const u8, ""));
        }
    }

    return termimage.replaceMarkers(
        allocator,
        md_rendered,
        all_markers.items,
        all_replacements.items,
    );
}

/// Render `content` as Markdown and output it.
/// `is_terminal`: whether stdout is a TTY (controls style + image support).
fn processContent(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    content: []const u8,
    style_name: []const u8,
    word_wrap: u32,
    use_pager: bool,
    use_tui: bool,
    is_terminal: bool,
    base_dir: ?[]const u8,
    conf: config.Config,
) !void {
    const normalized_content = try normalizeMarkdownLineEndings(allocator, content);
    defer if (normalized_content.ptr != content.ptr) allocator.free(normalized_content);

    var style_cfg = zchomd.style.getStandardStyle(style_name) orelse zchomd.style.dark;
    config.applyConfigToStyle(conf, &style_cfg);

    const img_format = termimage.detect(allocator, io, env, is_terminal, try std.Io.File.stdin().isTty(io));
    const use_kitty_text_sizing = termimage.detectTextSizing(allocator, env, is_terminal);

    var tr = zchomd.TermRenderer.init(allocator, .{
        .styles = style_cfg,
        .word_wrap = @intCast(word_wrap),
        .use_kitty_text_sizing = use_kitty_text_sizing,
    });

    const rendered: []u8 = blk: {
        const has_mermaid = std.mem.indexOf(u8, normalized_content, "```mermaid") != null;

        if (is_terminal) {
            break :blk try renderTerminal(allocator, io, env, &tr, normalized_content, has_mermaid, img_format, word_wrap, base_dir);
        }

        // Piped output: replace mermaid blocks with placeholder text.
        if (has_mermaid) {
            var result = try mermaid.extract(allocator, normalized_content, false);
            defer result.deinit(allocator);
            break :blk try tr.renderAlloc(result.markdown);
        }
        break :blk try tr.renderAlloc(normalized_content);
    };
    defer allocator.free(rendered);

    var echoes_styled_rendered: ?[]u8 = null;
    defer if (echoes_styled_rendered) |output| allocator.free(output);

    const output_rendered: []const u8 = blk: {
        if (comptime builtin.os.tag != .windows) break :blk rendered;
        if (!use_kitty_text_sizing) break :blk rendered;
        if (!try isEchoesTermProgram(allocator, env)) break :blk rendered;

        const output = try addEchoesStyleMetadataForOsc66(allocator, rendered);
        echoes_styled_rendered = output;
        break :blk output;
    };

    if (use_tui) {
        try tui.runPager(allocator, io, output_rendered);
    } else if (use_pager) {
        const default_pager = if (builtin.os.tag == .windows) "more" else "less -R";
        const pager_env = termimage.getEnv(allocator, env, "PAGER");
        defer if (pager_env) |pe| allocator.free(pe);
        const pager_cmd = conf.pager orelse pager_env orelse default_pager;
        try runExternalPager(allocator, io, output_rendered, pager_cmd);
    } else {
        try writeRenderedOutput(io, output_rendered, use_kitty_text_sizing);
    }
}

fn normalizeMarkdownLineEndings(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, content, '\r') == null) return content;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\r') {
            try out.append(allocator, '\n');
            if (i + 1 < content.len and content[i + 1] == '\n') {
                i += 1;
            }
        } else {
            try out.append(allocator, content[i]);
        }
    }

    return out.toOwnedSlice(allocator);
}

fn writeRenderedOutput(io: std.Io, rendered: []const u8, split_osc66: bool) !void {
    if (comptime builtin.os.tag != .windows) {
        try compat.stdoutWriteAll(io, rendered);
        return;
    }
    if (!split_osc66) {
        try compat.stdoutWriteAll(io, rendered);
        return;
    }

    var i: usize = 0;
    while (i < rendered.len) {
        const osc_start = std.mem.indexOfPos(u8, rendered, i, "\x1b]66;") orelse {
            try writeOutputChunk(io, rendered[i..]);
            return;
        };
        const chunk_start = osc66StyledChunkStart(rendered, i, osc_start);

        if (chunk_start > i) {
            try writeOutputChunk(io, rendered[i..chunk_start]);
        }

        const osc_end = osc66End(rendered, osc_start) orelse rendered.len;
        const chunk_end = osc66StyledChunkEnd(rendered, osc_end);
        try writeOutputChunk(io, rendered[chunk_start..chunk_end]);
        i = chunk_end;
    }
}

fn writeOutputChunk(io: std.Io, chunk: []const u8) !void {
    if (chunk.len == 0) return;
    try compat.stdoutWriteAll(io, chunk);
    if (comptime builtin.os.tag == .windows) {
        std.Io.sleep(io, .fromNanoseconds(std.time.ns_per_ms), .monotonic) catch {};
    }
}

fn osc66End(bytes: []const u8, start: usize) ?usize {
    if (start >= bytes.len) return null;

    var i = start + "\x1b]66;".len;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == 0x07) return i + 1;
        if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\') return i + 2;
    }
    return null;
}

fn osc66StyledChunkStart(bytes: []const u8, lower_bound: usize, osc_start: usize) usize {
    var start = osc_start;
    while (sgrSequenceStartEndingAt(bytes, lower_bound, start)) |sgr_start| {
        start = sgr_start;
    }
    return start;
}

fn osc66StyledChunkEnd(bytes: []const u8, osc_end: usize) usize {
    var end = osc_end;
    while (sgrSequenceEndStartingAt(bytes, end)) |sgr_end| {
        end = sgr_end;
    }
    return end;
}

fn sgrSequenceStartEndingAt(bytes: []const u8, lower_bound: usize, end: usize) ?usize {
    if (end <= lower_bound or end > bytes.len) return null;

    var i = end;
    while (i > lower_bound) {
        i -= 1;
        if (bytes[i] == 0x1b) {
            if (isSgrSequence(bytes[i..end])) return i;
            return null;
        }
    }
    return null;
}

fn sgrSequenceEndStartingAt(bytes: []const u8, start: usize) ?usize {
    if (start >= bytes.len or bytes[start] != 0x1b) return null;

    var i = start + 1;
    if (i >= bytes.len or bytes[i] != '[') return null;
    i += 1;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == 'm') return i + 1;
        if (bytes[i] < 0x30 or bytes[i] > 0x3f) return null;
    }
    return null;
}

fn isSgrSequence(bytes: []const u8) bool {
    if (bytes.len < 3) return false;
    if (bytes[0] != 0x1b or bytes[1] != '[' or bytes[bytes.len - 1] != 'm') return false;

    for (bytes[2 .. bytes.len - 1]) |b| {
        if (b < 0x30 or b > 0x3f) return false;
    }
    return true;
}

fn isEchoesTermProgram(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !bool {
    const term_program = termimage.getEnv(allocator, env, "TERM_PROGRAM") orelse return false;
    defer allocator.free(term_program);
    return std.mem.eql(u8, term_program, "Echoes");
}

const EchoesStyleMetadata = struct {
    fg: ?u8 = null,
    bg: ?u8 = null,
    bold: ?bool = null,

    fn any(self: EchoesStyleMetadata) bool {
        return self.fg != null or self.bg != null or self.bold != null;
    }
};

fn addEchoesStyleMetadataForOsc66(allocator: std.mem.Allocator, rendered: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < rendered.len) {
        const osc_start = std.mem.indexOfPos(u8, rendered, i, "\x1b]66;") orelse {
            try out.appendSlice(allocator, rendered[i..]);
            break;
        };
        const osc_end = osc66End(rendered, osc_start) orelse rendered.len;
        const style_start = osc66StyledChunkStart(rendered, i, osc_start);
        const style_meta = parseEchoesStyleMetadata(rendered[style_start..osc_start]);

        try out.appendSlice(allocator, rendered[i..osc_start]);
        if (style_meta.any()) {
            try appendEchoesStyledOsc66(allocator, &out, rendered[osc_start..osc_end], style_meta);
        } else {
            try out.appendSlice(allocator, rendered[osc_start..osc_end]);
        }
        i = osc_end;
    }

    return out.toOwnedSlice(allocator);
}

fn appendEchoesStyledOsc66(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    osc: []const u8,
    style_meta: EchoesStyleMetadata,
) !void {
    const meta_end = std.mem.indexOfScalarPos(u8, osc, "\x1b]66;".len, ';') orelse {
        try out.appendSlice(allocator, osc);
        return;
    };

    try out.appendSlice(allocator, osc[0..meta_end]);
    if (style_meta.fg) |fg| {
        const meta = try std.fmt.allocPrint(allocator, ":e_fg={d}", .{fg});
        defer allocator.free(meta);
        try out.appendSlice(allocator, meta);
    }
    if (style_meta.bg) |bg| {
        const meta = try std.fmt.allocPrint(allocator, ":e_bg={d}", .{bg});
        defer allocator.free(meta);
        try out.appendSlice(allocator, meta);
    }
    if (style_meta.bold) |bold| {
        const meta = try std.fmt.allocPrint(allocator, ":e_bold={d}", .{@intFromBool(bold)});
        defer allocator.free(meta);
        try out.appendSlice(allocator, meta);
    }
    try out.appendSlice(allocator, osc[meta_end..]);
}

fn parseEchoesStyleMetadata(sgr_bytes: []const u8) EchoesStyleMetadata {
    var meta = EchoesStyleMetadata{};

    var i: usize = 0;
    while (i < sgr_bytes.len) {
        const end = sgrSequenceEndStartingAt(sgr_bytes, i) orelse break;
        applySgrToEchoesStyleMetadata(&meta, sgr_bytes[i + 2 .. end - 1]);
        i = end;
    }

    return meta;
}

fn applySgrToEchoesStyleMetadata(meta: *EchoesStyleMetadata, params: []const u8) void {
    var parsed_buf: [16]u16 = undefined;
    var parsed_len: usize = 0;

    if (params.len == 0) {
        parsed_buf[0] = 0;
        parsed_len = 1;
    } else {
        var it = std.mem.splitScalar(u8, params, ';');
        while (it.next()) |part| {
            if (parsed_len >= parsed_buf.len) break;
            parsed_buf[parsed_len] = std.fmt.parseInt(u16, part, 10) catch 0;
            parsed_len += 1;
        }
    }

    var i: usize = 0;
    while (i < parsed_len) {
        const code = parsed_buf[i];
        switch (code) {
            0 => {
                meta.* = .{};
                i += 1;
            },
            1 => {
                meta.bold = true;
                i += 1;
            },
            22 => {
                meta.bold = false;
                i += 1;
            },
            39 => {
                meta.fg = null;
                i += 1;
            },
            49 => {
                meta.bg = null;
                i += 1;
            },
            38, 48 => {
                if (i + 2 < parsed_len and parsed_buf[i + 1] == 5 and parsed_buf[i + 2] <= 255) {
                    if (code == 38) {
                        meta.fg = @intCast(parsed_buf[i + 2]);
                    } else {
                        meta.bg = @intCast(parsed_buf[i + 2]);
                    }
                    i += 3;
                } else {
                    i += 1;
                }
            },
            else => i += 1,
        }
    }
}

test {
    // Pull in tests from imported modules so `zig build test` runs them;
    // Zig only auto-discovers tests in the root source file otherwise. Each
    // file must be referenced directly — referencing image.zig does not
    // transitively include imagesize.zig's tests.
    _ = @import("termimage.zig");
    _ = @import("image.zig");
    _ = @import("imagesize.zig");
    _ = @import("config.zig");
}

test "osc66End accepts BEL terminator" {
    const s = "\x1b]66;s=2;Hi\x07rest";
    try std.testing.expectEqual(@as(?usize, 12), osc66End(s, 0));
}

test "osc66End accepts ST terminator" {
    const s = "\x1b]66;s=2;Hi\x1b\\rest";
    try std.testing.expectEqual(@as(?usize, 13), osc66End(s, 0));
}

test "OSC 66 chunk keeps adjacent SGR styling sequences" {
    const s = "A\x1b[38;5;39m\x1b[48;5;57m\x1b[1m\x1b]66;s=3;H\x07\x1b[0mB";
    const osc_start = std.mem.indexOf(u8, s, "\x1b]66;").?;
    const osc_end = osc66End(s, osc_start).?;

    try std.testing.expectEqual(@as(usize, 1), osc66StyledChunkStart(s, 0, osc_start));
    try std.testing.expectEqual(s.len - 1, osc66StyledChunkEnd(s, osc_end));
}

test "OSC 66 chunk does not absorb styled text before the sequence" {
    const s = "\x1b[31mA\x1b]66;s=2;B\x07\x1b[0m";
    const osc_start = std.mem.indexOf(u8, s, "\x1b]66;").?;

    try std.testing.expectEqual(osc_start, osc66StyledChunkStart(s, 0, osc_start));
}

test "Echoes OSC 66 metadata carries adjacent SGR colors" {
    const s = "\x1b[38;5;228m\x1b[48;5;63m\x1b[1m\x1b]66;s=3;Heading\x07\x1b[0m";
    const result = try addEchoesStyleMetadataForOsc66(std.testing.allocator, s);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "\x1b]66;s=3:e_fg=228:e_bg=63:e_bold=1;Heading\x07"));
}

test "Echoes OSC 66 metadata is not added without adjacent SGR" {
    const s = "plain \x1b]66;s=2;Heading\x07";
    const result = try addEchoesStyleMetadataForOsc66(std.testing.allocator, s);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(s, result);
}

test "CRLF markdown line endings are normalized before block rendering" {
    const md =
        "# Title\r\n" ++
        "\r\n" ++
        "| A | B |\r\n" ++
        "|---|---|\r\n" ++
        "| one | two |\r\n" ++
        "\r\n" ++
        "```sh\r\n" ++
        "zig build\r\n" ++
        "```\r\n" ++
        "\r\n" ++
        "After\r\n";

    const normalized = try normalizeMarkdownLineEndings(std.testing.allocator, md);
    defer if (normalized.ptr != md.ptr) std.testing.allocator.free(normalized);

    var tr = zchomd.TermRenderer.init(std.testing.allocator, .{
        .styles = zchomd.style.notty,
        .word_wrap = 80,
    });
    const rendered = try tr.renderAlloc(normalized);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "+"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "zig build"));
    try std.testing.expect(std.mem.containsAtLeast(u8, rendered, 1, "After"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, rendered, "```"));
}

/// Pipe `content` through the external pager ($PAGER or "less -R").
fn runExternalPager(allocator: std.mem.Allocator, io: std.Io, content: []const u8, pager_cmd: []const u8) !void {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    var it = std.mem.tokenizeScalar(u8, pager_cmd, ' ');
    while (it.next()) |part| try parts.append(allocator, part);

    if (parts.items.len == 0) {
        try compat.stdoutWriteAll(io, content);
        return;
    }

    var child = try std.process.spawn(io, .{
        .argv = parts.items,
        .stdin = .pipe,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    if (child.stdin) |stdin| {
        try compat.writeFileAll(io, stdin, content);
        stdin.close(io);
        child.stdin = null;
    }

    _ = try child.wait(io);
}

fn printHelp(io: std.Io) void {
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
    compat.stdoutWriteAll(io, help) catch {};
}
