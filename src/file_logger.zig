//! Small utility to redirect logs to a file.
const std = @import("std");

var log_file_writer_mutex: std.Thread.Mutex = .{};
var log_file_writer: std.io.BufferedWriter(1024 * 8, std.fs.File.Writer) = undefined;

const Config = struct {
    stderr_level: ?std.log.Level,
    final_flush_retries: u16,
    stderr_excluded_scopes: []const []const u8,
};
var config: Config = undefined;

pub const InitConfig = struct {
    stderr_level: ?std.log.Level = null,
    final_flush_retries: u16 = 100,
};
pub fn init(
    rel_outpath: []const u8,
    cfg: InitConfig,
    comptime stderr_excluded_scopes: []const @Type(.EnumLiteral),
) !void {
    config = .{
        .stderr_level = cfg.stderr_level,
        .final_flush_retries = cfg.final_flush_retries,
        .stderr_excluded_scopes = comptime blk: {
            var names: []const []const u8 = &.{};
            for (stderr_excluded_scopes) |tag| {
                names = names ++ &[_][]const u8{@tagName(tag)};
            }
            break :blk names;
        },
    };
    log_file_writer = .{
        .unbuffered_writer = .{
            .context = try std.fs.cwd().createFile(rel_outpath, .{}),
        },
    };
}
pub fn deinit() void {
    var i: usize = 0;
    while (std.meta.isError(log_file_writer.flush())) : (i += 1) {
        if (i >= config.final_flush_retries) {
            std.debug.print("Failed to flush log file buffer.\n", .{});
            break;
        }
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

    if (std.sort.binarySearch([]const u8, @tagName(scope), config.stderr_excluded_scopes, void{}, struct {
        fn compare(ctx: void, lhs: []const u8, rhs: []const u8) std.math.Order {
            ctx;
            return std.mem.order(u8, lhs, rhs);
        }
    }.compare) == null) {
        if (config.stderr_level) |stderr_level| {
            if (@enumToInt(message_level) <= @enumToInt(stderr_level)) {
                std.log.defaultLog(message_level, scope, format, args);
            }
        }
    }

    writer.print(format ++ "\n", args) catch return;
}
