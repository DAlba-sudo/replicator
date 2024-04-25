const std = @import("std");
const posix = std.posix;

pub const Context = struct {
    pub const Category = enum {
        Input,
        Output,
        Listener,
        Unknown,
    };
    category: Category = .Unknown,
    fd: posix.fd_t,
};