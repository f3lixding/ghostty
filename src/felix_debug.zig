const std = @import("std");

pub fn waitForDebugger() !void {
    std.debug.print("JJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJ\n", .{});
    const pid = @as(u32, @intCast(std.c.getpid()));
    const process_ready_path = "/tmp/.pid";
    const ready_file = try std.fs.createFileAbsolute(process_ready_path, .{ .read = true });
    defer ready_file.close();
    const alloc = std.heap.page_allocator;
    const pid_as_str = try std.fmt.allocPrint(alloc, "{}\n", .{pid});
    defer alloc.free(pid_as_str);
    const bytes_written = try ready_file.write(pid_as_str);
    _ = bytes_written;

    const debugger_ready_path = "/tmp/.ready";
    while (true) {
        const res = std.fs.accessAbsolute(debugger_ready_path, .{});
        res catch |err| {
            std.log.warn("error accessing debugger ready file: {}", .{err});
            std.Thread.sleep(std.time.ns_per_s * 1);
            continue;
        };
        break;
    }

    try std.fs.deleteFileAbsolute(process_ready_path);
    try std.fs.deleteFileAbsolute(debugger_ready_path);
}
