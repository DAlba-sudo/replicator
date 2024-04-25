const Config = @import("./replica/configuration.zig").Configuration;

const inputs = [_][]const u8{
    "192.168.1.123",
};
const outputs = [_][]const u8{
    "127.0.0.1",
    "192.168.1.115",
};

// This is where you can perform customizations to your replication
// server. There are more options than just inputs, outputs. The rest have
// some sensible defaults, typically based on the number of inputs/outputs that
// you've provided. If you're unsure what types of customizations are availble,
// you can check out the file at "src/replica/configuration.zig".
pub const config: Config = .{
    .inputs = &inputs,
    .outputs = &outputs,
    .async_timeout = 500,
};
