const std = @import("std");

const posix = std.posix;
const linux = std.os.linux;

const Address = std.net.Address;

// replicator configuration options such as allowed inputs, expected outputs,
// buffer sizes, and other information can be found here.
const Config = struct {
    inputs: [][]const u8,
    outputs: [][]const u8,
    sz_read_buff: usize,
};

const Category = enum {
    Input,
    Output,
    Unknown,
    Listener,
};

// each socket connection has contextual information that we can
// make use of at runtime such as it's type, metrics, etc.
const Context = struct {
    is_active: bool = false,
    category: Category = .Unknown,

    fd: posix.fd_t = -1,
};

test "context comptime backing array allocation" {
    const alloc_amt = 3;

    var backing: [alloc_amt * @sizeOf(Context)]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&backing);

    _ = try fba.allocator().create(Context);
    _ = try fba.allocator().create(Context);
    const ptr = try fba.allocator().create(Context);
    fba.allocator().destroy(ptr);
    _ = try fba.allocator().create(Context);

    try std.testing.expectError(std.mem.Allocator.Error.OutOfMemory, fba.allocator().create(Context));
}

// the replicator will categorize connections to it's listening socket as input
// or output; it then will multiplex the input's data to all the outputs, while providing
// redundancy based "hot swapping" and metric exports for performance monitoring.
pub fn Replicator(comptime conf: Config) type {
    const max_sockets = conf.inputs.len + conf.outputs.len + 1;

    return struct {
        // synchronization
        should_shutdown: bool = false,

        // some backing structures

        // epoll globals
        epfd: i32 = -1,

        // context management
        sid: usize = 0, //socket id, a zero-based counter that can be used to access the context struct
        contexts: [max_sockets]Context = [_]Context{.{}} ** max_sockets,
        outputs: [conf.outputs.len]i32 = [_]i32{-1} ** conf.outputs.len,

        // globals
        lsocket: posix.socket_t = undefined,
        laddr: Address = Address.initIp4(.{ 0, 0, 0, 0 }, 0),
        input_read_buffer: [conf.sz_read_buff]u8 = [_]u8{0} ** conf.sz_read_buff,

        // used for starting the replicator, iface is the ip to listen on, port is the port
        // to listen on.
        pub fn serve(self: *@This(), iface: []const u8, port: u16) !void {
            self.conn_addr_allocator = std.heap.FixedBufferAllocator.init(&self.connection_addr_backing);

            // initial socket setup
            self.laddr = try Address.parseIp4(iface, port);
            self.lsocket = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
            try posix.bind(self.lsocket, &self.laddr.any, self.laddr.getOsSockLen());
            try posix.listen(self.lsocket, conf.outputs.len);

            // epoll setup
            self.epfd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
            try self.register_socket(self.lsocket, .Listener);

            // event loop has started...
            try self.event_loop();
        }

        // used for cases where we need to perform a shutdown (i.e., SIGINT, SIGTERM, etc).
        pub fn shutdown(self: *@This()) void {
            std.debug.print("[Log] Shutdown commencing...\n", .{});
            self.should_shutdown = true;
            defer posix.close(self.lsocket);

            for (self.outputs) |output| {
                if (output == -1)
                    continue;
                posix.close(output);
            }
        }

        // used for registering a new event with the epoll event file descriptor
        fn register_socket(self: *@This(), fd: i32, category: Category) !void {
            var event = linux.epoll_event{ .events = linux.EPOLL.IN, .data = .{ .u64 = self.sid } };
            try posix.epoll_ctl(
                self.epfd,
                linux.EPOLL.CTL_ADD,
                fd,
                &event,
            );

            const ctx = &self.contexts[self.sid];
            ctx.is_active = true;
            ctx.fd = fd;
            ctx.category = category;

            // increment by one
            self.sid += 1;
            return self.sid - 1;
        }

        // the event loop is in charge of reading from the epoll events and taking actions that
        // are based on the fd that is being read from.
        fn event_loop(self: *@This()) !void {
            std.debug.print("[Log] Event loop is starting...\n", .{});
            var events = [_]linux.epoll_event{.{ .events = linux.EPOLL.IN, .data = .{ .u64 = 0 } }} ** (max_sockets);

            while (!self.should_shutdown) {
                _ = posix.epoll_wait(self.epfd, &events, -1);
                for (events) |ev| {
                    const context: *Context = &self.contexts[ev.data.u32];

                    // ensures that the event is from an active socket
                    if (!context.is_active) {
                        unreachable;
                    }

                    switch (context.category) {
                        .Input => {
                            const n = try posix.read(context.fd, &self.input_read_buffer);

                            // send to outputs
                            for (self.outputs) |output| {
                                const w = try posix.write(output, self.input_read_buffer[0..n]);

                                // there was a mismatch between what was written to the output, and what was recvd on the input,
                                // this is probably something that should be logged.
                                if (w != n) {
                                    unreachable;
                                }
                            }
                        },
                        .Output => {
                            unreachable;
                        },
                        .Listener => {},
                        else => {},
                    }
                }
            }
        }
    };
}

fn getConnection(lsocket: posix.fd_t) !std.meta.Tuple([]const type{ posix.fd_t, []const u8 }) {
    _ = lsocket;
}
