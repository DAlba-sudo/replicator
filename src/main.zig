const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const clap = @import("clap");
const replicate = @import("./replica/server.zig");

// variable initialization
const conf = @import("./config.zig").config;
var replicator = replicate.Replicator(conf){};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help           Display this help and exit.
        \\-p, --port <u16>     Port to listen on.
        \\<str>...
        \\
    );

    const res = try clap.parse(clap.Help, &params, clap.parsers.default, .{
        .allocator = gpa.allocator(),
    });
    
    if (res.positionals.len == 1 and res.args.port != null) {
        std.debug.print("Listening on {?s}:{?d}\n", .{ res.positionals[0], res.args.port });

        // register a sigint signal
        register_sigint();

        // start serving the replicator
        try replicator.serve(res.positionals[0], res.args.port.?);
    } else {
        std.debug.print(
            \\  
            \\  Thanks for checking this out!
            \\  -p, --port          The port number to bind the listener socket to.
            \\  <str>               A positional argument corresponding to the interface 
            \\                      the socket will listen on (i.e., 127.0.0.1, etc).
            \\  Example:
            \\      replicator -p 9090 0.0.0.0
            \\
            \\
        , .{});
    }
}

fn register_sigint() void {
    // register shutdown with SIGINT
    const action = linux.Sigaction{
        .handler = .{ .handler = shutdown },
        .mask = [_]u32{0} ** 32,
        .flags = 0,
    };

    const err = linux.sigaction(linux.SIG.INT, &action, null);
    std.debug.assert(err == 0);
}

fn shutdown(int: i32) callconv(.C) void {
    _ = int;
    replicator.shutdown();
}
