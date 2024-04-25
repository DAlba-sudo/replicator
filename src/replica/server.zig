const std = @import("std");
const Configuration = @import("./configuration.zig").Configuration;
const Context = @import("./contexts.zig").Context;

const posix = std.posix;
const linux = std.os.linux;
const Address = std.net.Address;

pub fn Replicator(comptime conf: Configuration, comptime T: type) type {
    const max_sockets = 1 + conf.inputs.len + conf.outputs.len;
    const context_sz = @alignOf(Context) + @sizeOf(Context) + (@sizeOf(Context) % @alignOf(Context));

    // TODO: implement the "serializer" for structs...
    _ = T;

    return struct {
        // configuration
        conf: Configuration = conf,

        // backing structures for fixed buffer allocators...
        ctx_pointer_list: [max_sockets]?usize = [1]?usize{null} ** max_sockets,
        context_backing: [max_sockets * context_sz]u8 = [1]u8{0} ** (max_sockets * context_sz),
        address_backing: [21]u8 = [1]u8{0} ** 21,
        input_recv_buff: [conf.sz_input_read_buff]u8 = [1]u8{0} ** conf.sz_input_read_buff,

        // all the relevant allocators
        ctx_allocator: std.heap.FixedBufferAllocator = undefined,
        addr_allocator: std.heap.FixedBufferAllocator = undefined,

        // async related
        epfd: i32 = undefined,
        events: [max_sockets]linux.epoll_event = undefined,

        // state management
        should_shutdown: bool = false,

        // listener socket related
        lsocket: posix.socket_t = undefined,
        laddr: Address = undefined,

        pub fn init(self: *@This()) void {
            self.ctx_allocator = std.heap.FixedBufferAllocator.init(&self.context_backing);
            self.addr_allocator = std.heap.FixedBufferAllocator.init(&self.address_backing);
        }

        pub fn shutdown(self: *@This()) void {
            std.debug.print("Attempting shutdown...", .{});
            self.should_shutdown = true;

            // close all the pointers in the pointer list
            for (self.ctx_pointer_list) |ctx_ptr| {
                if (ctx_ptr) |ptr| {
                    const item: *Context = @ptrFromInt(ptr);
                    posix.close(item.fd);
                }
            }

            posix.close(self.epfd);
            posix.close(self.lsocket);
            std.process.exit(0);
        }

        pub fn serve(self: *@This(), iface: []const u8, port: u16) !void {
            self.init();

            // epoll initialization
            self.epfd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
            errdefer posix.close(self.epfd);

            // listening socket creation + initialization
            self.laddr = try Address.parseIp4(iface, port);
            self.lsocket = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0);
            try posix.bind(self.lsocket, &self.laddr.any, self.laddr.getOsSockLen());
            try posix.listen(self.lsocket, self.conf.socket_backlog);
            errdefer posix.close(self.lsocket);

            // registering the socket as a listener with epoll
            const item: *Context = try self.ctx_allocator.allocator().create(Context);
            item.category = .Listener;
            item.fd = self.lsocket;

            try self.register_with_epoll(item);
            std.debug.print("[Log] Finished socket and epoll initialization...\n", .{});

            // start the event loop
            try self.event_loop();
        }

        fn event_loop(self: *@This()) !void {
            std.debug.print("[Log] Starting event loop...\n", .{});
            while (!self.should_shutdown) {
                const n = posix.epoll_wait(
                    self.epfd,
                    &self.events,
                    conf.async_timeout,
                );

                var ev: linux.epoll_event = undefined;
                for (0..n) |i| {
                    ev = self.events[i];
                    const item: *Context = @ptrFromInt(ev.data.ptr);

                    if ((ev.events | linux.EPOLL.HUP) != 0) {
                        std.debug.print("[Info] Potentially closed connection for fd: {d}\n", .{item.fd});
                    }

                    try self.handle_async(item);
                }
            }
        }

        fn handle_async(self: *@This(), item: *Context) !void {
            switch (item.category) {
                .Input => {
                    const n = try posix.read(item.fd, &self.input_recv_buff);
                    if (n == 0) {
                        if (item.ptr_loc) |i| {
                            self.ctx_pointer_list[i] = null;
                        }
                        posix.close(item.fd);
                        self.ctx_allocator.allocator().destroy(item);
                    }

                    try self.replicate(self.input_recv_buff[0..n]);
                },
                .Output => {
                    const n = try posix.read(item.fd, &self.input_recv_buff);
                    if (n == 0) {
                        if (item.ptr_loc) |i| {
                            self.ctx_pointer_list[i] = null;
                        }
                        posix.close(item.fd);
                        self.ctx_allocator.allocator().destroy(item);
                    }
                },
                .Listener => {
                    var conn_addr: Address = Address.initIp4(.{ 0, 0, 0, 0 }, 0);
                    var conn_addr_len = conn_addr.getOsSockLen();

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

                            for (0..self.ctx_pointer_list.len) |i| {
                                if (self.ctx_pointer_list[i] == null) {
                                    self.ctx_pointer_list[i] = @intFromPtr(new_conn);
                                    new_conn.ptr_loc = i;
                                    std.debug.print("[Info] Set ctx pointer to index: {d}\n", .{i});
                                    break;
                                }
                            }

                            // register the item with epoll
                            try self.register_with_epoll(new_conn);
                            std.debug.print("Registered {} (fd: {d}) as [{s}]\n", .{ conn_addr, conn, @tagName(category) });
                        },
                    }
                },
                else => {},
            }
        }

        fn replicate(self: *@This(), data: []const u8) !void {
            // run the input through the provided serialization method
            // and output it to the outputs...
            for (self.ctx_pointer_list) |context_ptr| {
                if (context_ptr) |ptr| {
                    const out: *Context = @ptrFromInt(ptr);
                    if (out.category != .Output) {
                        continue;
                    }

                    const w = try posix.write(out.fd, data);
                    if (w == 0) {
                        // report that the output is no longer potentially recv data...
                        std.debug.print("[Log] Output was written 0 bytes...\n", .{});
                    }
                }
            }
        }

        fn register_with_epoll(self: *@This(), item: *Context) !void {
            var ev = linux.epoll_event{ .events = linux.EPOLL.IN | linux.EPOLL.HUP, .data = .{ .ptr = @intFromPtr(item) } };
            try posix.epoll_ctl(
                self.epfd,
                linux.EPOLL.CTL_ADD,
                item.fd,
                &ev,
            );
        }

        fn categorize_connection(self: *@This(), address: Address) !Context.Category {
            const conn_str = try std.fmt.allocPrint(
                self.addr_allocator.allocator(),
                "{}",
                .{address},
            );
            defer self.addr_allocator.allocator().free(conn_str);

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
