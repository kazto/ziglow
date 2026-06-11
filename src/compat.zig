const std = @import("std");

pub fn cwdOpenFile(io: std.Io, path: []const u8, options: std.Io.Dir.OpenFileOptions) !std.Io.File {
    return std.Io.Dir.cwd().openFile(io, path, options);
}

pub fn cwdCreateFile(io: std.Io, path: []const u8, options: std.Io.Dir.CreateFileOptions) !std.Io.File {
    return std.Io.Dir.cwd().createFile(io, path, options);
}

pub fn cwdDeleteFile(io: std.Io, path: []const u8) !void {
    return std.Io.Dir.cwd().deleteFile(io, path);
}

pub fn cwdAccess(io: std.Io, path: []const u8, options: std.Io.Dir.AccessOptions) !void {
    return std.Io.Dir.cwd().access(io, path, options);
}

pub fn readFileAlloc(io: std.Io, file: std.Io.File, allocator: std.mem.Allocator, limit: usize) ![]u8 {
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(limit));
}

pub fn writeFileAll(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

pub fn stdoutWriteAll(io: std.Io, bytes: []const u8) !void {
    return writeFileAll(io, std.Io.File.stdout(), bytes);
}

pub fn stderrWriteAll(io: std.Io, bytes: []const u8) !void {
    return writeFileAll(io, std.Io.File.stderr(), bytes);
}

pub fn stdinReadAllAlloc(io: std.Io, allocator: std.mem.Allocator, limit: usize) ![]u8 {
    return readFileAlloc(io, std.Io.File.stdin(), allocator, limit);
}

pub fn milliTimestamp(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}
