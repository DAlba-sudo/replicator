const std = @import("std");
const Configuration = @import("./configuration.zig").Configuration;
const Context = @import("./contexts.zig").Context;

const posix = std.posix;
const linux = std.os.linux;
const Address = std.net.Address;

pub fn Replicator(comptime conf: Configuration, comptime T: type) type {
    const max_sockets = 1 + conf.inputs.len + conf.outputs.len;
    
    // TODO: implement the "serializer"
    _ = T;

    return struct {
        // configuration
        conf: Configuration = conf,

        // backing structures for fixed buffer allocators...
        ctx_pointer_list: [max_sockets]i32 = [1]u8{-1} ** max_sockets,
        contexts: [max_sockets * @sizeOf(Context)]u8 = [1]u8{0} ** max_sockets * @sizeOf(Context),
        address_backing: [21]u8 = [1]u8{0} ** 21,

        // all the relevant allocators
        ctx_allocator: std.heap.FixedBufferAllocator,
        addr_allocator: std.heap.FixedBufferAllocator,

        // async related
        epfd: ?i32 = null,
        events: [max_sockets]linux.epoll_event = undefined,

        // state management
        should_shutdown: bool = false,

        // listener socket related
        lsocket: posix.socket_t = undefined,

        pub fn init() @This() {}
        pub fn shutdown(self: *@This()) void {
            _ = self;
        }

        pub fn event_loop(self: *@This()) !void {
            while (!self.should_shutdown) {
                const n = posix.epoll_wait(
                    self.epfd,
                    &self.events,
                    1e3,
                );

                for (self.events, 0..n) |ev, _| {
                    const item: *Context = @ptrCast(ev.data.ptr);

                    try self.handle_async(item);
                }
            }
        }

        fn handle_async(self: *@This(), item: *Context) !void {
            switch (item.category) {
                .Input => {
                    // TODO: implement
                    unreachable;
                },
                .Output => {
                    // TODO: implement
                    unreachable;
                },
                .Listener => {
                    const conn_addr: Address = Address.initIp4(.{ 0, 0, 0, 0 }, 0);
                    const conn_addr_len = conn_addr.getOsSockLen();

                    // accept the connection
                    const conn = try posix.accept(
                        self.lsocket,
                        &conn_addr.any,
                        &conn_addr_len,
                        posix.SOCK.NONBLOCK,
                    );

                    const category: Context.Category = try self.categorize_connection(conn_addr);
                    switch (category) {
                        .Unknown => {
                            posix.close(conn);
                        },
                        else => {
                            // add to the context pool and register with epoll
                            errdefer posix.close(conn);
                            const new_conn: *Context = try self.ctx_allocator.allocator().create(Context);
                            new_conn.fd = conn;
                            new_conn.category = category;

                            for (0..max_sockets) |i| {
                                if (self.ctx_pointer_list[i] == -1) {
                                    self.ctx_pointer_list[i] = @intFromPtr(item);
                                }
                            }

                            // register the item with epoll
                            try self.register_with_epoll(new_conn);
                        },
                    }
                },
            }
        }

        fn register_with_epoll(self: *@This(), item: *Context) !void {
            try posix.epoll_ctl(
                self.epfd,
                linux.EPOLL.CTL_ADD,
                item.fd,
                .{ .events = linux.EPOLL.IN, .data = .{ .ptr = @intFromPtr(item) } },
            );
        }

        fn categorize_connection(self: *@This(), address: Address) !Context.Category {
            const conn_str = try std.fmt.allocPrint(
                self.addr_allocator.allocator(),
                "{}",
                .{address},
            );

            const colon_index = std.mem.indexOf(u8, conn_str, ":");
            if (colon_index) |index| {
                const fixed_addr = conn_str[0..index];
                for (self.conf.inputs) |in| {
                    if (std.mem.eql(u8, in, fixed_addr)) {
                        return Context.Category.Input;
                    }
                }

                for (self.conf.outputs) |out| {
                    if (std.mem.eql(u8, out, fixed_addr)) {
                        return Context.Category.Output;
                    }
                }
            }

            return Context.Category.Unknown;
        }
    };
}
