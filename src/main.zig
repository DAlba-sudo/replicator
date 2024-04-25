const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const clap = @import("clap");

fn shutdown(int: i32) callconv(.C) void {
    _ = int;
    replicator.shutdown();
}

pub fn main() !void {
    const action = linux.Sigaction{
        .handler = .{ .handler = shutdown },
        .mask = [_]u32{0} ** 32,
        .flags = 0,
    };
    const err = linux.sigaction(linux.SIG.INT, &action, null);
    std.debug.assert(err == 0);

    try replicator.serve("127.0.0.1", 9090);
}
