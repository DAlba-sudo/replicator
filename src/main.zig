const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const clap = @import("clap");
const replicate = @import("./replica/server.zig");

// variable initialization
const conf = @import("./config.zig").config;
var replicator = replicate.Replicator(conf, u8){};

fn shutdown(int: i32) callconv(.C) void {
    _ = int;
    replicator.shutdown();
}

pub fn main() !void {   
    // register shutdown with SIGINT
    const action = linux.Sigaction{
        .handler = .{ .handler = shutdown },
        .mask = [_]u32{0} ** 32,
        .flags = 0,
    };

    const err = linux.sigaction(linux.SIG.INT, &action, null);
    std.debug.assert(err == 0);

    // start serving the replicator
    try replicator.serve("0.0.0.0", 9090);
}
