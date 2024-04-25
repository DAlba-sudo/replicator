const std = @import("std");
const posix = std.posix;
const Address = std.net.Address;
const linux = std.os.linux;

// Globals
var socket: posix.socket_t = undefined;
var laddr: Address = Address.initIp4(.{ 127, 0, 0, 1 }, 9090);
pub var should_shutdown: bool = false;
var epfd: i32 = -1;

// Type Definitions
const ReplicatorConnType = enum {
    Unknown,
    Input,
    Output,
};

const ReplicatorContext = struct {
    fd: posix.fd_t,
    conn_remote: []const u8,
    conn_remote_port: u16,
    conn_type: ReplicatorConnType,
};

const FdContextMap = std.AutoHashMap(i32, ReplicatorContext);

pub const ReplicatorConfig = struct {
    // flag related configurations

    pub const IPClassificationMode = enum {
        Runtime,
        Comptime,
        NotSpecified,
        Testing,
    };

    // specified when the inputs and outputs are all known at comptime. An
    // ip that attempts to connect at runtime, which was not specified at
    // comptime, will not be allowed to connect.
    ip_classification_mode: IPClassificationMode = .NotSpecified,
    ip_allow_any_ouptut: bool = false,

    // server configuration
    listen_backlog: u31 = 10,

    // declarative configurations
    AllowedInputs: [][]const u8,
    AllowedOutputs: ?[][]const u8 = null,
};

pub const Replicator = struct {
    conf: ReplicatorConfig,
    allocator: std.mem.Allocator,

    // maps the file descriptors to replicator contexts for
    // existing connections
    map: FdContextMap,
    events: []linux.epoll_event,

    // configuration related settings
    pub fn init(comptime configuration: ReplicatorConfig, allocator: std.mem.Allocator) !Replicator {

        // perform some pre-checks on the config provided for errors
        try check_conf(configuration);

        // some handy pre-calculations
        comptime var min_events = configuration.AllowedInputs.len;
        if (configuration.AllowedOutputs) |outputs| {
            min_events += outputs.len;
        }
        const epoll_ev = try allocator.alloc(linux.epoll_event, min_events);

        return Replicator{
            .conf = configuration,
            .allocator = allocator,
            .map = FdContextMap.init(allocator),
            .events = epoll_ev,
        };
    }

    pub fn deinit(self: *@This()) void {
        defer self.map.deinit();
        var ctx_iterator = self.map.iterator();
        while (ctx_iterator.next()) |ctx| {
            posix.close(ctx.value_ptr.*.fd);
        }

        self.allocator.free(self.events);
    }

    pub fn serve(self: *@This(), iface: []const u8, port: u16) !void {
        laddr = try Address.parseIp4(iface, port);

        // socket creation and cleanup (via defers)
        socket = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
        defer posix.close(socket);

        try posix.bind(socket, &laddr.any, laddr.getOsSockLen());
        try posix.listen(socket, self.conf.listen_backlog);

        // epoll creation and initialization
        epfd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
        defer posix.close(epfd);

        var socket_event: linux.epoll_event = .{ .data = .{ .fd = socket }, .events = linux.EPOLL.IN };
        try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, socket, &socket_event);

        try self.event_loop();
    }

    pub fn event_loop(self: *@This()) !void {
        var client_addr: Address = Address.initIp4(.{ 0, 0, 0, 0 }, 0);
        var client_addr_len: posix.socklen_t = client_addr.getOsSockLen();

        var client_addr_as_string: [50]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&client_addr_as_string);

        while (!should_shutdown) {
            const n = posix.epoll_wait(epfd, self.events, -1);
            if (n == 0) {
                continue;
            }

            for (self.events) |ev| {
                if (ev.data.fd == socket) {
                    // this is an accept event that needs to be handled...
                    const conn: posix.fd_t = try posix.accept(
                        socket,
                        &client_addr.any,
                        &client_addr_len,
                        posix.SOCK.NONBLOCK,
                    );
                    std.debug.print("Connection from: {}\n", .{client_addr});
                    const remote_as_string = try std.fmt.allocPrint(fba.allocator(), "{}", .{client_addr});
                    const colon_index = std.mem.indexOf(u8, remote_as_string, ":");

                    const context = ReplicatorContext{
                        .fd = conn,
                        .conn_type = .Unknown,
                        .conn_remote_port = client_addr.getPort(),
                        .conn_remote = remote_as_string[0..colon_index.?],
                    };

                    var connection_ev: linux.epoll_event = .{ .data = .{ .fd = conn }, .events = linux.EPOLL.IN };
                    try self.map.put(conn, context);
                    try posix.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, conn, &connection_ev);
                } else if (self.map.getEntry(ev.data.fd)) |entry| {
                    const context = entry.value_ptr;
                    switch (context.conn_type) {
                        ReplicatorConnType.Input => {
                            var buf: [1024]u8 = undefined;

                            // read from input and pipe to the outputs
                            const amount_read = try posix.read(context.fd, &buf);
                            if (std.mem.eql(u8, buf[0..amount_read-1], "!!close")) {
                                return;
                            }

                            var value_iter = self.map.valueIterator();
                            while (value_iter.next()) |value| {
                                if (value.conn_type == .Output) {
                                    _ = try posix.write(value.fd, buf[0..amount_read]);
                                }
                            }
                        },
                        ReplicatorConnType.Output => {
                            unreachable;
                        },
                        ReplicatorConnType.Unknown => {
                            std.debug.print("Unknown connection type encountered... attempting to check.\n", .{});
                            var found = false;
                            for (self.conf.AllowedInputs) |input| {
                                if (std.mem.eql(u8, input, context.conn_remote)) {
                                    context.conn_type = .Input;
                                    found = true;

                                    break;
                                }
                            }

                            if (!found) {
                                context.conn_type = .Output;
                                try posix.shutdown(context.fd, .recv);
                                try posix.epoll_ctl(epfd, linux.EPOLL.CTL_DEL, context.fd, null);
                            }
                        },
                    }
                }
            }
        }
    }
};

fn check_conf(comptime conf: ReplicatorConfig) !void {
    switch (conf.ip_classification_mode) {
        ReplicatorConfig.IPClassificationMode.Comptime => {
            if (conf.AllowedInputs.len == 0) {
                @compileError("allowed inputs is null or empty and comptime ip classification was chosen");
            }

            if (conf.AllowedOutputs == null) {
                @compileError("allowed outputs is null and comptime ip classification was chosen");
            } else if (conf.AllowedOutputs.?.len == 0) {
                @compileError("allowed outputs is empty and comptime ip classification was chosen");
            }
        },
        ReplicatorConfig.IPClassificationMode.Runtime => {},
        ReplicatorConfig.IPClassificationMode.NotSpecified => {
            @compileError("must specify an ip classification mode.");
        },
        else => {},
    }
}
