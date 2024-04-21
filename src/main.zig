const std = @import("std");
const posix = std.posix;

const clap = @import("clap");
const Replicator = @import("./replicator.zig").Replicator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var r = Replicator.init(allocator);
    try r.serve("127.0.0.1", 9090);
}

fn spawn_test_replicator(allocator: std.mem.Allocator) !void {
    var replicator = Replicator.init(allocator);
    try replicator.serve("127.0.0.1", 9090);
}

fn spawn_oneshot_connection() !void {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 9090);

    const socket = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    defer posix.close(socket);

    std.time.sleep(3e9);
    try posix.connect(socket, &addr.any, addr.getOsSockLen());
}

test "memory leak test" {
    const replicator_thread = try std.Thread.spawn(
        .{},
        spawn_test_replicator,
        .{std.testing.allocator},
    );
    const test_client_thread = try std.Thread.spawn(
        .{},
        spawn_oneshot_connection,
        .{},
    );
    test_client_thread.join();
    replicator_thread.join();
}
