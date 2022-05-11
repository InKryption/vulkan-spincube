//! Small utility to redirect logs to a file.
const std = @import("std");

var log_file_writer_mutex: std.Thread.Mutex = .{};
var log_file_writer: std.io.BufferedWriter(1024 * 8, std.fs.File.Writer) = undefined;

const Config = struct {
    stderr_level: ?std.log.Level = null,
};
var config: Config = undefined;

pub fn init(rel_outpath: []const u8, cfg: Config) !void {
    config = cfg;
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

    if (scope == .default) {
        if (config.stderr_level) |stderr_level| {
            switch (stderr_level) {
                .err => if (message_level == .err) std.log.defaultLog(message_level, scope, format, args),
                .warn => if (@enumToInt(message_level) <= @enumToInt(std.log.Level.warn)) std.log.defaultLog(message_level, scope, format, args),
                .info => if (@enumToInt(message_level) <= @enumToInt(std.log.Level.info)) std.log.defaultLog(message_level, scope, format, args),
                .debug => if (@enumToInt(message_level) <= @enumToInt(std.log.Level.debug)) std.log.defaultLog(message_level, scope, format, args),
            }
        }
    }
    writer.print(format ++ "\n", args) catch return;
}
