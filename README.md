# ziglow

CLIでMarkdownをレンダリングする、Zigによる [charmbracelet/glow](https://github.com/charmbracelet/glow) の再実装。

## 依存モジュール

| モジュール | 役割 |
|---|---|
| [zchomd](../zchomd) | Markdownパーサー＆ANSIレンダラー (glamour相当) |
| [zchomptic](../zchomptic) | TUIフレームワーク / Elmアーキテクチャ (bubbletea相当) |
| [zcholor](../zcholor) | ターミナルスタイリング (lipgloss相当) |

## ビルド

```
zig build          # zig-out/bin/ziglow を生成
zig build run      # ビルド＆実行
zig build test     # テスト実行
```

必要な Zig バージョン: **0.15.2 以降**

## 使い方

```
ziglow [OPTIONS] [FILE|DIR|-]
```

### 入力ソース

| 指定 | 動作 |
|---|---|
| `FILE` | 指定した Markdown ファイルをレンダリング |
| `DIR` | ディレクトリ内の README.md を探してレンダリング |
| `-` | 標準入力から読み込む |
| (省略) | stdin がパイプなら stdin、そうでなければカレントディレクトリ |

### オプション

| オプション | 説明 | デフォルト |
|---|---|---|
| `-s`, `--style <name>` | スタイル: `dark` / `light` / `notty` / `auto` | `auto` |
| `-w`, `--width <n>` | 折り返し幅 (0 = 端末幅、最大120) | 端末幅 |
| `-p`, `--pager` | `$PAGER` (未設定時は `less -r`) に渡す | — |
| `-t`, `--tui` | 内蔵TUIページャーで表示 | — |
| `-h`, `--help` | ヘルプを表示 | — |
| `-V`, `--version` | バージョンを表示 | — |

`auto` スタイルは、TTYに出力するとき `dark`、パイプに出力するとき `notty` を自動選択します。

## 設定ファイル

`ziglow` は以下のパスにある TOML 形式の設定ファイルを読み込みます。

- `$XDG_CONFIG_HOME/ziglow/ziglow.toml`
- または `~/.config/ziglow/ziglow.toml`

起動オプションが指定された場合は、設定ファイルの値よりもオプションが優先されます。

### 設定項目

| キー | 説明 | 例 |
|---|---|---|
| `style` | デフォルトのスタイル | `"dark"` / `"light"` / `"notty"` / `"auto"` |
| `width` | 折り返し幅 | `100` |
| `pager` | 使用する外部ページャー | `"less -R"` |
| `builtin_tui` | デフォルトで内蔵TUIを使用するか | `true` / `false` |
| `h1_foreground` | 見出し1の前景色 | `"#1f1f1f"` / `"228"` |
| `h1_background` | 見出し1の背景色 | `"#a0a0a0"` / `"63"` |
| `h1_scale` | 見出し1の拡大率（対応端末のみ） | `3.0` |
| `h2_foreground` | 見出し2の前景色 | `"#1f1f1f"` |
| `h2_background` | 見出し2の背景色 | `"#a0a0a0"` |
| `h2_scale` | 見出し2の拡大率（対応端末のみ） | `1.5` |

### 設定例

```toml
style = "dark"
width = 100
pager = "less -R"
builtin_tui = false

h1_foreground = "#282c34"
h1_background = "#e06c75"
h1_scale = 3.0

h2_foreground = "#e06c75"
h2_scale = 1.5
```

### 使用例

```sh
# ファイルをレンダリング
ziglow README.md

# カレントディレクトリの README を表示
ziglow

# stdin からパイプ
cat CHANGELOG.md | ziglow

# 明示的に stdin を指定
ziglow -

# ライトスタイルで幅60
ziglow -s light -w 60 README.md

# 外部ページャーで表示
ziglow -p README.md

# 内蔵TUIページャーで表示
ziglow -t README.md
```

## TUIページャーのキーバインド

| キー | 動作 |
|---|---|
| `j` / `↓` | 1行下へ |
| `k` / `↑` | 1行上へ |
| `d` / `Ctrl+D` | 半ページ下へ |
| `u` / `Ctrl+U` | 半ページ上へ |
| `f` / `Space` / `Ctrl+F` / `PageDown` | 1ページ下へ |
| `b` / `Ctrl+B` / `PageUp` | 1ページ上へ |
| `g` / `Home` | 先頭へ |
| `G` / `End` | 末尾へ |
| `q` / `Ctrl+C` | 終了 |

## プロジェクト構成

```
ziglow/
├── build.zig          # ビルド定義
├── build.zig.zon      # 依存関係 (zchomd, zchomptic, zcholor)
└── src/
    ├── main.zig       # CLI エントリポイント、引数解析、レンダリング dispatch
    ├── tui.zig        # TUI ページャーモデル (zchomptic)
    └── root.zig       # ライブラリスタブ
```
