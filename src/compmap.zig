const std = @import("std");
const assert = std.debug.assert;

// a basic compile time backed, no allocation, "hash" map. 
pub fn Map(comptime V: type) type {
    return struct {
        capacity: usize,
        size: usize = 0,
        backing_array: []V,
        
        pub fn init(backing_array: []V) @This() {
            return .{
                .backing_array = backing_array,
                .capacity = backing_array.len,
            };
        }

        pub fn put(self: *@This(), key: i32, item: V) !void {
            assert((self.size + 1) < self.capacity);

            const insertion_index = self.backing_array.len % key;
            self.backing_array[insertion_index] = item;
        }
    };
}