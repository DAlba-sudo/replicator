// a replicator instance will take an input and have a set of outputs that have registered
// to receive data.
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const ConnectionList = std.ArrayList(posix.socket_t);

const ReplicatorConnType = enum {
    Input,
    Output,
    Unknown,
};

const ReplicatorEvent = struct {
    fd: linux.fd_t,
    ConnectionType: ReplicatorConnType = .Unknown,
};

const ReplicatorEntities = struct {
    epoll_ev: linux.epoll_event = .{ .data = .{ .ptr = undefined }, .events = 0 },
    context: ReplicatorEvent,
};

pub const Replicator = struct {
    // memory allocation related
    allocator: std.mem.Allocator,

    // networking related
    socket: posix.socket_t = undefined,
    listener_event: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .ptr = undefined } },
    outputs: ConnectionList,

    // async related
    primary_epoll: i32 = undefined,
    contexts: std.ArrayList(ReplicatorEntities),
    pub fn init(allocator: std.mem.Allocator) Replicator {
        return .{
            .allocator = allocator,
            .outputs = ConnectionList.init(allocator),
            .contexts = std.ArrayList(ReplicatorEntities).init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        defer self.outputs.deinit();

        const listener_event_ptr: *ReplicatorEvent = @ptrFromInt(self.listener_event.data.ptr);
        self.allocator.destroy(listener_event_ptr);

        // close out of the epoll fd
        posix.close(self.primary_epoll);
        posix.close(self.socket);

        // close out of all connections in the connection list
        for (self.outputs.items) |conn| {
            posix.close(conn);
        }
    }

    pub fn serve(self: *@This(), iface: []const u8, port: u16) !void {
        const laddr = try std.net.Address.parseIp4(iface, port);
        defer self.deinit();

        // start by trying to register and bind to the
        // listening port/interface.
        self.socket = try posix.socket(
            posix.AF.INET,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
            0,
        );

        // setup the listener event data structure
        const listener_event = try self.allocator.create(ReplicatorEvent);
        listener_event.fd = self.socket;
        self.listener_event.data.ptr = @intFromPtr(listener_event);

        try posix.bind(self.socket, &laddr.any, laddr.getOsSockLen());
        try posix.listen(self.socket, 5);

        // try registering the listener socket with epoll so that we can have async accept
        self.primary_epoll = try posix.epoll_create1(linux.EPOLL.CLOEXEC);

        try posix.epoll_ctl(
            self.primary_epoll,
            linux.EPOLL.CTL_ADD,
            self.socket,
            &self.listener_event,
        );

        // no further setup is deemed necessary, starting the event loop
        try self.event_loop();
    }

    fn event_loop(self: *@This()) !void {
        var connection_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
        var connection_addr_len = connection_addr.getOsSockLen();

        var events: [20]linux.epoll_event = undefined;

        while (true) {
            const n = posix.epoll_wait(
                self.primary_epoll,
                &events,
                -1,
            );

            for (0..n) |i| {
                const event: *ReplicatorEvent = @ptrFromInt(events[i].data.ptr);
                if (event.fd == self.socket) {
                    // accept the connection and prepare it for categorization
                    const conn = try posix.accept(
                        self.socket,
                        &connection_addr.any,
                        &connection_addr_len,
                        0,
                    );
                    try self.contexts.append(.{ .context = .{ .fd = conn } });

                    const conn_watcher = &self.contexts.getLast();
                    conn_watcher.epoll_ev.data.ptr = @intFromPtr(conn_watcher);

                    try posix.epoll_ctl(
                        self.primary_epoll,
                        linux.EPOLL.CTL_ADD,
                        conn,
                        conn_watcher.epoll_ev,
                    );
                } else {
                    switch (event.ConnectionType) {
                        ReplicatorConnType.Unknown => {
                            std.debug.print("Unknown Connection Type! Closing...\n", .{});
                            defer posix.close(event.fd);
                            try posix.epoll_ctl(
                                self.primary_epoll,
                                linux.EPOLL.CTL_DEL,
                                event.fd,
                                null,
                            );
                        },
                    }
                }
            }
        }
    }

    fn replicate(self: *@This(), data: []const u8) !void {
        for (self.outputs.items) |output| {
            try posix.write(output, data);
        }
    }
};
