//! Decode just the pixel dimensions (width, height) from an image file's
//! header bytes, without a full image decoder. Supports the raster formats
//! ziglow inlines: PNG, JPEG, GIF, BMP, and WebP. Returns null when the
//! format is unrecognized or the header is too short / malformed.

const std = @import("std");

pub const Dim = struct { w: u32, h: u32 };

pub fn dimensions(bytes: []const u8) ?Dim {
    if (pngDim(bytes)) |d| return d;
    if (gifDim(bytes)) |d| return d;
    if (bmpDim(bytes)) |d| return d;
    if (jpegDim(bytes)) |d| return d;
    if (webpDim(bytes)) |d| return d;
    return null;
}

fn pngDim(b: []const u8) ?Dim {
    const sig = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
    if (b.len < 24) return null;
    if (!std.mem.eql(u8, b[0..8], &sig)) return null;
    // IHDR is the first chunk: width at byte 16, height at 20 (big-endian).
    const w = std.mem.readInt(u32, b[16..20], .big);
    const h = std.mem.readInt(u32, b[20..24], .big);
    if (w == 0 or h == 0) return null;
    return .{ .w = w, .h = h };
}

fn gifDim(b: []const u8) ?Dim {
    if (b.len < 10) return null;
    if (!std.mem.eql(u8, b[0..6], "GIF87a") and !std.mem.eql(u8, b[0..6], "GIF89a")) return null;
    const w = std.mem.readInt(u16, b[6..8], .little);
    const h = std.mem.readInt(u16, b[8..10], .little);
    if (w == 0 or h == 0) return null;
    return .{ .w = w, .h = h };
}

fn bmpDim(b: []const u8) ?Dim {
    if (b.len < 26) return null;
    if (b[0] != 'B' or b[1] != 'M') return null;
    const w = std.mem.readInt(i32, b[18..22], .little);
    const h = std.mem.readInt(i32, b[22..26], .little);
    const aw: u32 = @intCast(@abs(w));
    const ah: u32 = @intCast(@abs(h));
    if (aw == 0 or ah == 0) return null;
    return .{ .w = aw, .h = ah };
}

fn jpegDim(b: []const u8) ?Dim {
    if (b.len < 4) return null;
    if (b[0] != 0xff or b[1] != 0xd8) return null; // SOI
    var i: usize = 2;
    while (i + 9 < b.len) {
        if (b[i] != 0xff) {
            i += 1;
            continue;
        }
        const marker = b[i + 1];
        // Standalone markers (no length): padding 0xff, RSTn, SOI/EOI.
        if (marker == 0xff) {
            i += 1;
            continue;
        }
        if (marker == 0xd8 or marker == 0xd9 or (marker >= 0xd0 and marker <= 0xd7)) {
            i += 2;
            continue;
        }
        const seg_len = std.mem.readInt(u16, b[i + 2 ..][0..2], .big);
        if (seg_len < 2) return null;
        // SOF0..SOF15 carry the frame size, except DHT(C4), JPG(C8), DAC(CC).
        if (marker >= 0xc0 and marker <= 0xcf and
            marker != 0xc4 and marker != 0xc8 and marker != 0xcc)
        {
            if (i + 9 >= b.len) return null;
            const h = std.mem.readInt(u16, b[i + 5 ..][0..2], .big);
            const w = std.mem.readInt(u16, b[i + 7 ..][0..2], .big);
            if (w == 0 or h == 0) return null;
            return .{ .w = w, .h = h };
        }
        i += 2 + seg_len;
    }
    return null;
}

fn webpDim(b: []const u8) ?Dim {
    if (b.len < 30) return null;
    if (!std.mem.eql(u8, b[0..4], "RIFF") or !std.mem.eql(u8, b[8..12], "WEBP")) return null;
    const fourcc = b[12..16];
    if (std.mem.eql(u8, fourcc, "VP8X")) {
        // Extended: canvas width-1 / height-1 as 24-bit LE at offset 24/27.
        const w = (@as(u32, b[24]) | (@as(u32, b[25]) << 8) | (@as(u32, b[26]) << 16)) + 1;
        const h = (@as(u32, b[27]) | (@as(u32, b[28]) << 8) | (@as(u32, b[29]) << 16)) + 1;
        return .{ .w = w, .h = h };
    }
    if (std.mem.eql(u8, fourcc, "VP8 ")) {
        // Lossy: 14-bit width/height in the keyframe header at offset 26/28.
        if (b.len < 30) return null;
        const w = (@as(u32, b[26]) | (@as(u32, b[27]) << 8)) & 0x3fff;
        const h = (@as(u32, b[28]) | (@as(u32, b[29]) << 8)) & 0x3fff;
        if (w == 0 or h == 0) return null;
        return .{ .w = w, .h = h };
    }
    if (std.mem.eql(u8, fourcc, "VP8L")) {
        // Lossless: 14-bit width-1/height-1 packed after the 0x2f signature.
        if (b.len < 25 or b[20] != 0x2f) return null;
        const bits = @as(u32, b[21]) | (@as(u32, b[22]) << 8) |
            (@as(u32, b[23]) << 16) | (@as(u32, b[24]) << 24);
        const w = (bits & 0x3fff) + 1;
        const h = ((bits >> 14) & 0x3fff) + 1;
        return .{ .w = w, .h = h };
    }
    return null;
}

test "pngDim reads IHDR" {
    var b = [_]u8{0} ** 24;
    @memcpy(b[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a });
    std.mem.writeInt(u32, b[16..20], 640, .big);
    std.mem.writeInt(u32, b[20..24], 480, .big);
    const d = pngDim(&b).?;
    try std.testing.expectEqual(@as(u32, 640), d.w);
    try std.testing.expectEqual(@as(u32, 480), d.h);
}

test "gifDim reads logical screen size" {
    var b = [_]u8{0} ** 10;
    @memcpy(b[0..6], "GIF89a");
    std.mem.writeInt(u16, b[6..8], 100, .little);
    std.mem.writeInt(u16, b[8..10], 50, .little);
    const d = gifDim(&b).?;
    try std.testing.expectEqual(@as(u32, 100), d.w);
    try std.testing.expectEqual(@as(u32, 50), d.h);
}

test "pngDim rejects bad signature" {
    var b = [_]u8{0} ** 24;
    @memcpy(b[0..8], &[_]u8{ 0x89, 'P', 'N', 'X', 0x0d, 0x0a, 0x1a, 0x0a });
    std.mem.writeInt(u32, b[16..20], 640, .big);
    std.mem.writeInt(u32, b[20..24], 480, .big);
    try std.testing.expectEqual(@as(?Dim, null), pngDim(&b));
}

test "pngDim rejects short header" {
    const b = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
    try std.testing.expectEqual(@as(?Dim, null), pngDim(&b));
}

test "pngDim rejects zero dimension" {
    var b = [_]u8{0} ** 24;
    @memcpy(b[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a });
    std.mem.writeInt(u32, b[16..20], 0, .big);
    std.mem.writeInt(u32, b[20..24], 480, .big);
    try std.testing.expectEqual(@as(?Dim, null), pngDim(&b));
}

test "gifDim accepts GIF87a" {
    var b = [_]u8{0} ** 10;
    @memcpy(b[0..6], "GIF87a");
    std.mem.writeInt(u16, b[6..8], 12, .little);
    std.mem.writeInt(u16, b[8..10], 34, .little);
    const d = gifDim(&b).?;
    try std.testing.expectEqual(@as(u32, 12), d.w);
    try std.testing.expectEqual(@as(u32, 34), d.h);
}

test "gifDim rejects bad magic" {
    var b = [_]u8{0} ** 10;
    @memcpy(b[0..6], "GIF99a");
    std.mem.writeInt(u16, b[6..8], 12, .little);
    std.mem.writeInt(u16, b[8..10], 34, .little);
    try std.testing.expectEqual(@as(?Dim, null), gifDim(&b));
}

test "gifDim rejects short header" {
    const b = [_]u8{ 'G', 'I', 'F', '8', '9' };
    try std.testing.expectEqual(@as(?Dim, null), gifDim(&b));
}

test "bmpDim reads BITMAPINFOHEADER" {
    var b = [_]u8{0} ** 26;
    b[0] = 'B';
    b[1] = 'M';
    std.mem.writeInt(i32, b[18..22], 640, .little);
    std.mem.writeInt(i32, b[22..26], 480, .little);
    const d = bmpDim(&b).?;
    try std.testing.expectEqual(@as(u32, 640), d.w);
    try std.testing.expectEqual(@as(u32, 480), d.h);
}

test "bmpDim takes absolute value of top-down height" {
    var b = [_]u8{0} ** 26;
    b[0] = 'B';
    b[1] = 'M';
    std.mem.writeInt(i32, b[18..22], 640, .little);
    std.mem.writeInt(i32, b[22..26], -480, .little); // top-down bitmap
    const d = bmpDim(&b).?;
    try std.testing.expectEqual(@as(u32, 640), d.w);
    try std.testing.expectEqual(@as(u32, 480), d.h);
}

test "bmpDim rejects bad magic" {
    var b = [_]u8{0} ** 26;
    b[0] = 'X';
    b[1] = 'M';
    std.mem.writeInt(i32, b[18..22], 640, .little);
    std.mem.writeInt(i32, b[22..26], 480, .little);
    try std.testing.expectEqual(@as(?Dim, null), bmpDim(&b));
}

test "bmpDim rejects short header" {
    const b = [_]u8{ 'B', 'M', 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(?Dim, null), bmpDim(&b));
}

test "bmpDim rejects zero dimension" {
    var b = [_]u8{0} ** 26;
    b[0] = 'B';
    b[1] = 'M';
    std.mem.writeInt(i32, b[18..22], 0, .little);
    std.mem.writeInt(i32, b[22..26], 480, .little);
    try std.testing.expectEqual(@as(?Dim, null), bmpDim(&b));
}

test "jpegDim finds SOF0" {
    // SOI, APP0 (len 4, 2 bytes payload), SOF0 (len 17, h=200 w=300).
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try list.appendSlice(std.testing.allocator, &[_]u8{ 0xff, 0xd8 });
    try list.appendSlice(std.testing.allocator, &[_]u8{ 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00 });
    try list.appendSlice(std.testing.allocator, &[_]u8{ 0xff, 0xc0, 0x00, 0x11, 0x08 });
    var hw: [4]u8 = undefined;
    std.mem.writeInt(u16, hw[0..2], 200, .big);
    std.mem.writeInt(u16, hw[2..4], 300, .big);
    try list.appendSlice(std.testing.allocator, &hw);
    try list.appendSlice(std.testing.allocator, &[_]u8{0} ** 10);
    const d = jpegDim(list.items).?;
    try std.testing.expectEqual(@as(u32, 300), d.w);
    try std.testing.expectEqual(@as(u32, 200), d.h);
}

test "jpegDim skips DHT (C4) before reaching SOF2" {
    // SOI, DHT (C4, a non-SOF marker in the C0..CF range), then SOF2.
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.testing.allocator);
    try list.appendSlice(std.testing.allocator, &[_]u8{ 0xff, 0xd8 });
    // DHT: marker C4, length 5 (2 + 3 payload bytes).
    try list.appendSlice(std.testing.allocator, &[_]u8{ 0xff, 0xc4, 0x00, 0x05, 0x00, 0x00, 0x00 });
    // SOF2 (progressive): length 17, precision 8, h=120 w=160.
    try list.appendSlice(std.testing.allocator, &[_]u8{ 0xff, 0xc2, 0x00, 0x11, 0x08 });
    var hw: [4]u8 = undefined;
    std.mem.writeInt(u16, hw[0..2], 120, .big);
    std.mem.writeInt(u16, hw[2..4], 160, .big);
    try list.appendSlice(std.testing.allocator, &hw);
    try list.appendSlice(std.testing.allocator, &[_]u8{0} ** 10);
    const d = jpegDim(list.items).?;
    try std.testing.expectEqual(@as(u32, 160), d.w);
    try std.testing.expectEqual(@as(u32, 120), d.h);
}

test "jpegDim rejects non-JPEG" {
    const b = [_]u8{ 0x00, 0xd8, 0x00, 0x00 };
    try std.testing.expectEqual(@as(?Dim, null), jpegDim(&b));
}

test "jpegDim returns null when no SOF present" {
    // SOI followed only by an APP0 segment, no frame header.
    const b = [_]u8{ 0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expectEqual(@as(?Dim, null), jpegDim(&b));
}

test "webpDim reads VP8X extended canvas" {
    var b = [_]u8{0} ** 30;
    @memcpy(b[0..4], "RIFF");
    @memcpy(b[8..12], "WEBP");
    @memcpy(b[12..16], "VP8X");
    // canvas width-1 / height-1 as 24-bit LE: 256x128.
    b[24] = 0xff; // 255 -> width 256
    b[27] = 0x7f; // 127 -> height 128
    const d = webpDim(&b).?;
    try std.testing.expectEqual(@as(u32, 256), d.w);
    try std.testing.expectEqual(@as(u32, 128), d.h);
}

test "webpDim reads VP8 lossy keyframe" {
    var b = [_]u8{0} ** 30;
    @memcpy(b[0..4], "RIFF");
    @memcpy(b[8..12], "WEBP");
    @memcpy(b[12..16], "VP8 ");
    // 14-bit width/height at offsets 26/28: 300x200.
    b[26] = 0x2c;
    b[27] = 0x01; // 0x012c = 300
    b[28] = 0xc8;
    b[29] = 0x00; // 0x00c8 = 200
    const d = webpDim(&b).?;
    try std.testing.expectEqual(@as(u32, 300), d.w);
    try std.testing.expectEqual(@as(u32, 200), d.h);
}

test "webpDim reads VP8L lossless header" {
    var b = [_]u8{0} ** 30;
    @memcpy(b[0..4], "RIFF");
    @memcpy(b[8..12], "WEBP");
    @memcpy(b[12..16], "VP8L");
    b[20] = 0x2f; // signature byte
    // bits = (w-1) | ((h-1) << 14), w=100, h=50 -> 0x000c4063, LE.
    b[21] = 0x63;
    b[22] = 0x40;
    b[23] = 0x0c;
    b[24] = 0x00;
    const d = webpDim(&b).?;
    try std.testing.expectEqual(@as(u32, 100), d.w);
    try std.testing.expectEqual(@as(u32, 50), d.h);
}

test "webpDim rejects bad RIFF/WEBP magic" {
    var b = [_]u8{0} ** 30;
    @memcpy(b[0..4], "RIFX");
    @memcpy(b[8..12], "WEBP");
    @memcpy(b[12..16], "VP8 ");
    try std.testing.expectEqual(@as(?Dim, null), webpDim(&b));
}

test "webpDim rejects unknown fourcc" {
    var b = [_]u8{0} ** 30;
    @memcpy(b[0..4], "RIFF");
    @memcpy(b[8..12], "WEBP");
    @memcpy(b[12..16], "XXXX");
    try std.testing.expectEqual(@as(?Dim, null), webpDim(&b));
}

test "webpDim rejects short header" {
    const b = [_]u8{ 'R', 'I', 'F', 'F' };
    try std.testing.expectEqual(@as(?Dim, null), webpDim(&b));
}

test "webpDim rejects VP8L without signature byte" {
    var b = [_]u8{0} ** 30;
    @memcpy(b[0..4], "RIFF");
    @memcpy(b[8..12], "WEBP");
    @memcpy(b[12..16], "VP8L");
    b[20] = 0x00; // missing 0x2f signature
    try std.testing.expectEqual(@as(?Dim, null), webpDim(&b));
}

test "dimensions dispatches by format" {
    // PNG
    var png = [_]u8{0} ** 24;
    @memcpy(png[0..8], &[_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a });
    std.mem.writeInt(u32, png[16..20], 8, .big);
    std.mem.writeInt(u32, png[20..24], 16, .big);
    const dp = dimensions(&png).?;
    try std.testing.expectEqual(@as(u32, 8), dp.w);
    try std.testing.expectEqual(@as(u32, 16), dp.h);

    // GIF
    var gif = [_]u8{0} ** 10;
    @memcpy(gif[0..6], "GIF89a");
    std.mem.writeInt(u16, gif[6..8], 3, .little);
    std.mem.writeInt(u16, gif[8..10], 4, .little);
    const dg = dimensions(&gif).?;
    try std.testing.expectEqual(@as(u32, 3), dg.w);
    try std.testing.expectEqual(@as(u32, 4), dg.h);

    // BMP
    var bmp = [_]u8{0} ** 26;
    bmp[0] = 'B';
    bmp[1] = 'M';
    std.mem.writeInt(i32, bmp[18..22], 5, .little);
    std.mem.writeInt(i32, bmp[22..26], 6, .little);
    const db = dimensions(&bmp).?;
    try std.testing.expectEqual(@as(u32, 5), db.w);
    try std.testing.expectEqual(@as(u32, 6), db.h);
}

test "dimensions returns null for unknown format" {
    const b = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 };
    try std.testing.expectEqual(@as(?Dim, null), dimensions(&b));
}

test "dimensions returns null for empty input" {
    const b = [_]u8{};
    try std.testing.expectEqual(@as(?Dim, null), dimensions(&b));
}
