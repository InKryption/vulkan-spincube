//! Small utility to redirect logs to a file.
const std = @import("std");

var log_file_writer_mutex: std.Thread.Mutex = .{};
var log_file_writer: std.io.BufferedWriter(1024 * 8, std.fs.File.Writer) = undefined;

var config: struct {
    stderr_level: ?std.log.Level,
    final_flush_retries: u16,
    included_scopes: ?[]const []const u8,
} = undefined;

pub const InitConfig = struct {
    stderr_level: ?std.log.Level = null,
    final_flush_retries: u16 = 100,
};
pub fn init(
    rel_outpath: []const u8,
    cfg: InitConfig,
    comptime maybe_included_scopes: ?[]const @Type(.EnumLiteral),
) !void {
    config = .{
        .stderr_level = cfg.stderr_level,
        .final_flush_retries = cfg.final_flush_retries,
        .included_scopes = if (maybe_included_scopes) |scopes| comptime included_scopes: {
            var included_scopes: []const []const u8 = &.{};
            for (scopes) |scope_tag| {
                if (std.sort.binarySearch([]const u8, @tagName(scope_tag), included_scopes, void{}, binaryStringSearch) == null) {
                    included_scopes = included_scopes ++ [_][]const u8{@tagName(scope_tag)};
                }
            }
            break :included_scopes included_scopes;
        } else null,
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
    const is_included_scope: bool = if (config.included_scopes) |scopes|
        (std.sort.binarySearch([]const u8, @tagName(scope), scopes, void{}, binaryStringSearch) != null)
    else
        true;

    if (scope == .default or is_included_scope) {
        if (config.stderr_level) |stderr_level| {
            if (@enumToInt(message_level) <= @enumToInt(stderr_level)) {
                std.log.defaultLog(message_level, scope, format, args);
            }
        }

        comptime var real_fmt: []const u8 = "";
        comptime real_fmt = real_fmt ++ message_level.asText();
        comptime if (scope != .default) {
            real_fmt = real_fmt ++ "(" ++ @tagName(scope) ++ ")";
        };
        comptime real_fmt = real_fmt ++ ": " ++ format ++ "\n";

        writer.print(real_fmt, args) catch return;
    }
}

fn binaryStringSearch(ctx: void, lhs: []const u8, rhs: []const u8) std.math.Order {
    ctx;
    return std.mem.order(u8, lhs, rhs);
}
