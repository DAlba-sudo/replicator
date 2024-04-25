const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const clap = @import("clap");

// replicator related
const replicate = @import("./replica/server.zig");

const inputs = [_][]const u8{"127.0.0.1"};
const outputs = [_][]const u8{"128.61.37.162"};
var replicator = replicate.Replicator(.{
    .inputs = &inputs,
    .outputs = &outputs,
}, u8){};

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

    try replicator.serve("0.0.0.0", 9090);
}
