# OSC 8 Hyperlinks Design

**Date:** 2026-06-19  
**Status:** Approved

## Overview

Add clickable hyperlinks to ziglow's Markdown output using the OSC 8 terminal escape sequence. When rendering to a TTY, HTTP/HTTPS links become clickable in supporting terminals (iTerm2, WezTerm, Kitty, foot, etc.). Local file links are displayed as paths only — no click behavior.

## Scope

- **In scope:** OSC 8 for `http://` and `https://` URLs in `.link` and `.auto_link` AST nodes
- **Out of scope:** Local file opening (ziglow/PAGER dispatch), TUI mode link navigation, non-HTTP URL schemes

## Data Flow

```
Markdown source
 → zchomd parser  (produces AST: link nodes with .url field)
 → zchomd renderer  (enable_osc8=true → wraps http/https URLs in OSC 8)
 → ANSI + OSC 8 output
 → stdout (TTY only)
```

## Components

### 1. `zig-pkg/zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI/src/renderer.zig` — Options

Add field to `Options` struct:

```zig
enable_osc8: bool = false,
```

Default `false` ensures no behavior change for existing callers.

### 2. `zig-pkg/zchomd-1.0.0-1u20dAWVAQAHstSpdAneR614wd_uMZUX6dIZOll_rZTI/src/renderer.zig` — Link rendering

Current output for `.link` node:

```
link text (https://example.com)
```

New output when `enable_osc8 = true` and URL starts with `http://` or `https://`:

```
ESC]8;;https://example.com BEL link text ESC]8;; BEL (https://example.com)
```

Where `ESC` = `\x1b`, `BEL` = `\x07`.

The link text becomes the clickable anchor. The URL in parentheses is displayed as plain text (current format preserved).

For `.auto_link` nodes (bare `<https://...>` syntax), apply the same OSC 8 wrapping around the URL text.

**URL filtering:** Only emit OSC 8 when `url` starts with `http://` or `https://`. Relative paths, absolute paths, and other schemes are rendered as plain text.

### 3. `src/main.zig` — TermRenderer initialization

Pass `enable_osc8` based on `is_terminal`:

```zig
var tr = zchomd.TermRenderer.init(allocator, .{
    .styles = style_cfg,
    .word_wrap = @intCast(word_wrap),
    .use_kitty_text_sizing = use_kitty_text_sizing,
    .enable_osc8 = is_terminal,
});
```

## Error Handling

No new failure modes. OSC 8 sequences are plain byte writes — if the terminal does not support them, it silently ignores them (graceful degradation).

## Testing

### zchomd unit tests (in `root.zig` or a new test file)

1. `enable_osc8 = true`, http URL → output contains `\x1b]8;;https://` sequence
2. `enable_osc8 = true`, local path URL → output does NOT contain `\x1b]8;`
3. `enable_osc8 = false`, http URL → output does NOT contain `\x1b]8;`
4. `auto_link` with https URL and `enable_osc8 = true` → output contains OSC 8 sequence

### ziglow integration check

- `is_terminal = false` (piped output) → `enable_osc8 = false`, no OSC 8 in output
