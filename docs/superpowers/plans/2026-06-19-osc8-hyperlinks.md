# OSC 8 Hyperlinks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make HTTP/HTTPS links in ziglow's rendered Markdown output clickable via OSC 8 hyperlink escape sequences.

**Architecture:** Add `enable_osc8: bool = false` to `zchomd`'s `Options` struct. When enabled, the renderer wraps link text in `\x1b]8;;URL\x07...\x1b]8;;\x07` sequences for `.link` and `.auto_link` AST nodes whose URL starts with `http://` or `https://`. ziglow passes `enable_osc8 = is_terminal` when initializing `TermRenderer`.

**Tech Stack:** Zig 0.15.2+, zchomd (vendored in `zig-pkg/`), zchomptic, zcholor

> **Note on `zig-pkg/` and `build.zig.zon`:** `build.zig.zon` references zchomd via a GitHub URL+hash. Changes to `zig-pkg/zchomd-.../` are NOT picked up by `zig build` until we switch to a path dependency. Task 0 handles this switch; Task 4 reverts it after publishing the updated zchomd.

---

## File Map

| File | Change |
|---|---|
| `build.zig.zon` | Temporarily switch zchomd to `.path` (Task 0), then restore URL after publish (Task 4) |
| `zig-pkg/zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI/src/renderer.zig` | Add `enable_osc8` to `Options`, add `isHttpUrl` helper, update `.link` and `.auto_link` rendering |
| `zig-pkg/zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI/src/root.zig` | Add OSC 8 unit tests |
| `src/main.zig` | Pass `enable_osc8 = is_terminal` to `TermRenderer.init`, add integration test |

---

## Task 0: Switch zchomd to local path dependency

**Files:**
- Modify: `build.zig.zon`

- [ ] **Step 1: Change zchomd entry in `build.zig.zon` from URL to path**

Replace:

```zig
.zchomd = .{
    .url = "git+https://github.com/kazto/zchomd.git#5a28d236ab005a9130a6b55b0fb4b5f2f255d0ae",
    .hash = "zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI",
},
```

With:

```zig
.zchomd = .{
    .path = "zig-pkg/zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI",
},
```

- [ ] **Step 2: Verify the build still compiles**

```
zig build
```

Expected: build succeeds, `zig-out/bin/ziglow` produced.

---

## Task 1: Add `enable_osc8` to Options and implement `.link` OSC 8

**Files:**
- Modify: `zig-pkg/zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI/src/renderer.zig`
- Modify: `zig-pkg/zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI/src/root.zig`

- [ ] **Step 1: Write three failing tests in `root.zig`**

Append to `zig-pkg/zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI/src/root.zig`:

```zig
test "osc8: http link emits OSC 8 hyperlink around link text" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tr = TermRenderer.init(allocator, .{ .styles = style.notty, .enable_osc8 = true });
    const result = try tr.renderAlloc("[Zig](https://ziglang.org)\n");
    defer allocator.free(result);

    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "\x1b]8;;https://ziglang.org\x07"));
    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "\x1b]8;;\x07"));
    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "Zig"));
    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "https://ziglang.org"));
}

test "osc8: local path link does not emit OSC 8" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tr = TermRenderer.init(allocator, .{ .styles = style.notty, .enable_osc8 = true });
    const result = try tr.renderAlloc("[docs](./another.md)\n");
    defer allocator.free(result);

    try testing.expect(!std.mem.containsAtLeast(u8, result, 1, "\x1b]8;"));
    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "docs"));
}

test "osc8: enable_osc8=false does not emit OSC 8 for http link" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tr = TermRenderer.init(allocator, .{ .styles = style.notty, .enable_osc8 = false });
    const result = try tr.renderAlloc("[Zig](https://ziglang.org)\n");
    defer allocator.free(result);

    try testing.expect(!std.mem.containsAtLeast(u8, result, 1, "\x1b]8;"));
}
```

- [ ] **Step 2: Run zchomd unit tests to confirm they fail**

```
cd "zig-pkg\zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI" && zig build test
```

Expected: compile error — field `enable_osc8` not found in `Options`.

- [ ] **Step 3: Add `enable_osc8` to `Options` and `isHttpUrl` helper in `renderer.zig`**

Change `Options` struct (lines 8–13 of `renderer.zig`):

```zig
pub const Options = struct {
    styles: style.StyleConfig = style.dark,
    word_wrap: usize = 80,
    preserve_newlines: bool = false,
    use_kitty_text_sizing: bool = false,
    enable_osc8: bool = false,
};
```

Add this private helper function anywhere before `RenderContext` (e.g. after line 13):

```zig
fn isHttpUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "https://");
}
```

- [ ] **Step 4: Run zchomd tests to confirm first two still fail (no OSC 8 emitted yet)**

```
cd "zig-pkg\zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI" && zig build test
```

Expected: tests "osc8: http link emits OSC 8..." and "osc8: local path..." fail. Third test passes.

- [ ] **Step 5: Update `.link` rendering in `renderInlineToWriter` to emit OSC 8**

Replace the `.link` branch in `renderInlineToWriter` (currently lines 504–516 of `renderer.zig`):

```zig
.link => {
    const lt_style = mergeStylePrimitive(parent_style, s.link_text);
    const use_osc8 = self.opts().enable_osc8 and node.url.len > 0 and isHttpUrl(node.url);
    if (use_osc8) {
        try writer.print("\x1b]8;;{s}\x07", .{node.url});
    }
    for (node.children.items) |child| {
        try self.renderInlineToWriter(writer, child, lt_style);
    }
    if (use_osc8) {
        try writer.writeAll("\x1b]8;;\x07");
    }
    if (node.url.len > 0) {
        try writer.writeAll(" (");
        try ansi_util.writeStyled(writer, s.link, node.url);
        try writer.writeByte(')');
    }
},
```

- [ ] **Step 6: Run zchomd tests and confirm all three pass**

```
cd "zig-pkg\zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI" && zig build test
```

Expected: all three "osc8:" tests pass.

- [ ] **Step 7: Commit**

Run from the ziglow repo root:

```
git add zig-pkg/zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI/src/renderer.zig
git add zig-pkg/zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI/src/root.zig
git commit -m "feat(zchomd): add OSC 8 hyperlink support for http/https links"
```

---

## Task 2: Add OSC 8 for `.auto_link` nodes

**Files:**
- Modify: `zig-pkg/zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI/src/renderer.zig`
- Modify: `zig-pkg/zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI/src/root.zig`

- [ ] **Step 1: Write failing test in `root.zig`**

Append to `root.zig`:

```zig
test "osc8: auto_link with https emits OSC 8" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tr = TermRenderer.init(allocator, .{ .styles = style.notty, .enable_osc8 = true });
    const result = try tr.renderAlloc("<https://ziglang.org>\n");
    defer allocator.free(result);

    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "\x1b]8;;https://ziglang.org\x07"));
    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "\x1b]8;;\x07"));
    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "https://ziglang.org"));
}
```

- [ ] **Step 2: Run zchomd tests to confirm the new test fails**

```
cd "zig-pkg\zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI" && zig build test
```

Expected: "osc8: auto_link with https emits OSC 8" fails (no OSC 8 in output).

- [ ] **Step 3: Update `.auto_link` rendering in `renderInlineToWriter`**

Replace the `.auto_link` branch (currently line 540–542 of `renderer.zig`):

```zig
.auto_link => {
    if (self.opts().enable_osc8 and isHttpUrl(node.url)) {
        try writer.print("\x1b]8;;{s}\x07", .{node.url});
        try ansi_util.writeStyled(writer, s.link, node.url);
        try writer.writeAll("\x1b]8;;\x07");
    } else {
        try ansi_util.writeStyled(writer, s.link, node.url);
    }
},
```

- [ ] **Step 4: Run zchomd tests and confirm all pass**

```
cd "zig-pkg\zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI" && zig build test
```

Expected: all four "osc8:" tests pass, no regressions.

- [ ] **Step 5: Commit**

Run from the ziglow repo root:

```
git add zig-pkg/zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI/src/renderer.zig
git add zig-pkg/zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI/src/root.zig
git commit -m "feat(zchomd): add OSC 8 support for auto_link nodes"
```

---

## Task 3: Wire `enable_osc8` in ziglow's `main.zig`

**Files:**
- Modify: `src/main.zig`

- [ ] **Step 1: Write integration test in `src/main.zig`**

Add the following test to `src/main.zig` (alongside the existing `test { ... }` block at the bottom of the file):

```zig
test "osc8 enabled for http link when is_terminal=true" {
    const zchomd = @import("zchomd");
    const allocator = std.testing.allocator;

    var tr = zchomd.TermRenderer.init(allocator, .{
        .styles = zchomd.style.notty,
        .enable_osc8 = true,
    });
    const result = try tr.renderAlloc("[Zig](https://ziglang.org)\n");
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "\x1b]8;;https://ziglang.org\x07"));
}
```

- [ ] **Step 2: Run ziglow tests to confirm the new test passes (zchomd already updated)**

```
zig build test
```

Expected: new test passes (zchomd already has the implementation from Tasks 1–2).

- [ ] **Step 3: Wire `enable_osc8` in `processContent`**

In `src/main.zig`, find the `TermRenderer.init` call inside `processContent` (around line 349) and add the `enable_osc8` field:

```zig
var tr = zchomd.TermRenderer.init(allocator, .{
    .styles = style_cfg,
    .word_wrap = @intCast(word_wrap),
    .use_kitty_text_sizing = use_kitty_text_sizing,
    .enable_osc8 = is_terminal,
});
```

- [ ] **Step 4: Build and run a quick smoke test**

```
zig build
echo "[Zig](https://ziglang.org)" | zig-out\bin\ziglow -
```

Expected: in a supporting terminal (WezTerm, Kitty, iTerm2, foot), the text "Zig" is rendered as a clickable hyperlink. In a plain terminal, the output looks identical to before.

- [ ] **Step 5: Run full test suite**

```
zig build test
```

Expected: all tests pass, no regressions.

- [ ] **Step 6: Commit**

```
git add src/main.zig
git commit -m "feat: enable OSC 8 hyperlinks in terminal output"
```

---

## Task 4: Publish zchomd and restore URL dependency

**Files:**
- Modify: `build.zig.zon`

- [ ] **Step 1: Push zchomd changes to GitHub**

The changes in `zig-pkg/zchomd-1.0.0-.../src/` need to be committed to the `kazto/zchomd` repository. Copy or push those changes upstream and note the new commit SHA.

- [ ] **Step 2: Get the new zchomd hash**

```
zig fetch --save git+https://github.com/kazto/zchomd.git#<NEW_COMMIT_SHA>
```

`zig fetch --save` updates `build.zig.zon` automatically with the new URL and hash.

- [ ] **Step 3: Verify build uses the new URL**

Confirm `build.zig.zon` no longer has `.path` for zchomd and has the new `.url` + `.hash`.

```
zig build test
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```
git add build.zig.zon
git commit -m "chore: update zchomd to version with OSC 8 support"
```
