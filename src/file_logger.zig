//! Small utility to redirect logs to a file.
const std = @import("std");

var log_file_writer_mutex: std.Thread.Mutex = .{};
var log_file_writer: std.io.BufferedWriter(1024 * 8, std.fs.File.Writer) = undefined;

pub fn init(rel_outpath: []const u8) !void {
    log_file_writer = .{
        .unbuffered_writer = .{
            .context = try std.fs.cwd().createFile(rel_outpath, .{}),
        },
    };
}
pub fn deinit() void {
    var i: usize = 0;
    while (std.meta.isError(log_file_writer.flush())) : (i += 1) {
        if (i > 100) break;
    }
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    log_file_writer_mutex.lock();
    defer log_file_writer_mutex.unlock();

    const writer = log_file_writer.writer();
    writer.writeAll(message_level.asText()) catch return;
    if (scope != .default) {
        writer.print("({s}): ", .{@tagName(scope)}) catch return;
    } else writer.writeAll(": ") catch return;

    writer.print(format ++ "\n", args) catch return;
}
