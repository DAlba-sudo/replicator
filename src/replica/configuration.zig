
pub const Configuration = struct {
    inputs: [][]const u8,
    outputs: [][]const u8,

    socket_backlog: u31 = 1,

    pub fn init(comptime inputs: [][]const u8, comptime outputs: [][]const u8) @This() {
        return .{
            .inputs = inputs,
            .outputs = outputs,

            .socket_backlog = inputs.len + outputs.len + 5,
        };
    }
};