# Echoes 端末での通常 Markdown 画像のインライン表示

日付: 2026-06-05
対象: ziglow

## 目的

Echoes 端末で実行したとき、通常の Markdown 画像 `![alt](path)` を
Kitty Graphics Protocol でインライン表示する。現状は mermaid 図のみが
画像化されており、通常画像は zchomd によって `Image: alt → url` という
テキストとして描画されるだけになっている。

## 確定要件

- **画像ソース:** ローカルファイルのみ。HTTP(s) などリモート取得は行わない。
- **対象画像:** 独立行の画像のみ(前後の空白を除いた行全体がちょうど 1 個の
  画像構文だけで構成される行)。段落テキスト中のインライン画像は対象外。
- **対応形式:** 主要ラスター形式 `png, jpg, jpeg, gif, bmp, webp`。
  生バイトを Kitty の `f=100` で渡すだけなので、Echoes の GdiPlus デコーダが
  これらを解釈できる。
- **表示経路:** 端末検出で `.kitty`(Echoes は `TERM_PROGRAM=Echoes` →
  `isKitty` → `.kitty`)。既存の `termimage.encodeKitty` /
  `termimage.replaceMarkers` をそのまま再利用する。

## アプローチ

**案A(採用):ziglow 側で前処理する(mermaid と同じパターン)。**

mermaid は既に「ziglow 側でテキストを前処理 → ユニークマーカーに置換 →
レンダリング後に `replaceMarkers` で画像へ差し替え」という形になっている。
通常画像も同じ形にするのが既存コードと最も一貫し、変更も 1 リポジトリで
完結する(zchomd 改修不要)。「独立行のみ」という要件のため自前パースの
複雑さも小さい。

却下した案:
- 案B(zchomd に画像マーカーのフックを追加)— 依存先改修+バージョン bump が
  必要で 2 リポジトリにまたがる。mermaid が ziglow 側前処理である現状と非対称。
- 案C(案Bの最小版)— 短所は B と同じ。

## アーキテクチャとデータフロー

```
markdown content
   │
   ├─[mermaid あり]→ mermaid.extract(use_markers=true) → markers + PNG群
   │                    (mermaid 置換済み markdown を後段へ)
   │
   └─ image.extract(md, base_dir)                       ← 新規
         ├─ 行走査(フェンスコードブロック除外)
         ├─ 「行全体が ![alt](path)」の独立行を検出
         ├─ 各画像をユニークマーカー(ZIGLOWIMAGE{n})に置換
         └─ 解決済み絶対パスを収集
   │
   ▼
tr.renderAlloc(markdown)   ← zchomd で描画(マーカーはテキスト行として残る)
   │
   ▼
各画像ファイルの生バイトを読み込み(読めなければ null)
   │
   ▼
termimage.replaceMarkers(rendered, markers, image_bytes, img_format, width)
   │   既存関数を再利用。null の画像はマーカー行をそのまま残す
   ▼
出力(Echoes では Kitty Graphics Protocol)
```

### mermaid との共存

mermaid 経路と画像経路の両方を走らせる。マーカー接頭辞を分離
(`ZIGLOWMERMAID` / `ZIGLOWIMAGE`)し、両方の markers と画像群(mermaid は
PNG バイト、通常画像はファイル読込バイト)を連結して `replaceMarkers` を
**1 回**呼ぶ。これにより mermaid 図と通常画像が混在する Markdown も扱える。

### パス解決

- 相対パスは Markdown ファイルのあるディレクトリ基準で解決する(CWD 基準ではない)。
- stdin / パイプ入力時はベースディレクトリが無いので CWD 基準にフォールバック。
- `processContent` にベースディレクトリ(`?[]const u8`)を渡す。`processFile` は
  対象ファイルのディレクトリを渡す。

## `image.zig` の API

mermaid と対称的な構造にする。

```zig
pub const marker_prefix = "ZIGLOWIMAGE";

pub const ImageResult = struct {
    markdown: []u8,        // 画像独立行をマーカーに置換後の Markdown
    markers: [][]u8,       // 各画像のマーカー文字列
    paths: [][]u8,         // 各画像の解決済み絶対パス(markers と並行)
    pub fn deinit(self: *ImageResult, allocator: std.mem.Allocator) void { ... }
};

/// base_dir: 相対パス解決の基準(null なら CWD)
pub fn extract(allocator: std.mem.Allocator, md: []const u8, base_dir: ?[]const u8) !ImageResult
```

## 独立行画像の検出ロジック

行走査し、フェンスコードブロック内は除外する。

1. `mermaid.zig` の `detectFenceOpen` / `isClosingFence` / `stripIndent` を共有する
   (`pub` 化して `image.zig` から参照、または共通 `fence.zig` に切り出し)。
   フェンスコードブロック内の行は対象外。
2. フェンス外の行について、前後の空白を trim した結果が **ちょうど 1 個の
   画像構文だけ**で構成されるかを判定:
   - パターン: `![` alt `](` path `)`、任意のタイトル付き
     `![alt](path "title")` / `(path 'title')`。
   - alt は任意(空でも可)。path は trim。`<path>` の山括弧囲みは剥がす。
   - 画像構文の前後に他の可視文字があれば独立行ではないとみなしスキップ。
3. path の拡張子を小文字化し、許可リスト `{png, jpg, jpeg, gif, bmp, webp}` に
   含まれる場合のみ画像化対象。含まれなければマーカー化せず元の行を残す
   (zchomd が通常どおりテキスト描画)。
4. URL スキーム(`http://`, `https://`, `data:` 等)を検出したらローカル対象外と
   してスキップ(マーカー化しない)。
5. 絶対パスはそのまま、相対パスは `base_dir`(なければ CWD)と結合して絶対パス化。
6. 対象行をマーカー `ZIGLOWIMAGE{n}` に置換し、解決済み絶対パスを記録。

### 非対象(YAGNI)

- 参照スタイル画像 `![alt][ref]`。
- 1 行に複数画像が並ぶケース(独立行 = 単一画像のみ)。

## main.zig の統合

`processContent` の `rendered` 生成ブロックを再構成する
(`is_terminal && img_format != .none` のとき):

1. mermaid があれば従来どおり `mermaid.extract(use_markers=true)` で markdown を
   変換し PNG 群を得る。
2. その(mermaid 置換済み)markdown に対して `image.extract(md, base_dir)` を実行し、
   画像マーカーとパス群を得る。
3. `tr.renderAlloc` でレンダリング。
4. mermaid の markers/PNG群 と 画像の markers/(ファイル読込)バイト群 を**連結**し、
   `replaceMarkers` を 1 回呼ぶ。画像バイトは `replaceMarkers` 直前に各パスを
   読み込み(`readToEndAlloc`、上限あり)。読めなければ `null` → マーカー行を残す。
5. mermaid が無い場合も `image.extract` 経路は走らせる(画像のみの Markdown 対応)。

## サイズ指定

mermaid と同じく `word_wrap`(描画幅セル数)を `width_cells` として渡す。
`encodeKitty` は `c={width_cells}` を出力し、Echoes は縦をアスペクト比から算出する。
mermaid と一貫した挙動。

## エラー処理(描画を壊さない)

- ファイルが存在しない / 読めない / サイズ超過 → その画像は `null`、マーカー行を
  残す(他の画像は表示)。
- `image.extract` 自体の失敗は致命的でないため、失敗時は元の markdown に
  フォールバックして通常描画。

## Windows / ConPTY 考慮

- OSC 66(Kitty Text Sizing)は Windows ConPTY が画面再構成で壊す既知問題がある
  (別途記録済み)。Kitty Graphics は **APC シーケンス**(`\x1b_G...`)で別物。
- 実際に Echoes 経由(ConPTY)で表示されるかは、実装後に検証ハーネス
  (`tmp/echoes-verify/capture.ps1`)でスクリーンショット確認する。
- もし APC も ConPTY で壊れる場合は、OSC 66 と同様に「ziglow からは修正不能・
  Echoes 側対応が必要」と切り分けて記録する(成功条件には含めるが、ziglow 側
  実装の責務外)。

## テスト(TDD)

`image.zig` の純粋関数に単体テスト:

- 独立行検出(alt 有無 / タイトル付き / 山括弧囲み)。
- フェンスコードブロック内の画像は非対象。
- 拡張子フィルタ(許可リスト外は非対象)。
- URL スキーム除外。
- 相対 → 絶対パス解決(base_dir あり / なし)。
- 複数画像の連番マーカー。
- 非独立行(段落テキスト中の画像)は非対象。

既存の `zig build test` に組み込む。視覚確認は検証ハーネスで実画像入り
Markdown を Echoes に流し `capture.ps1` でスクショする。

## 成功条件

- 独立行のローカル画像が Echoes(Windows)で Kitty Graphics Protocol により
  インライン表示される(検証ハーネスのスクショで確認)。
- mermaid 図と通常画像が混在しても両方表示される。
- 非対応端末(`.none`)や読めないファイルでは従来どおりテキスト / マーカーが残り、
  クラッシュしない。
