const std = @import("std");

pub fn ComptimeScope(comptime V_: type) type {
    return struct {
        keys: []const K = &.{},
        values: []const V = &.{},

        pub const K = []const u8;
        pub const V = V_;

        pub const empty: @This() = .{};

        pub fn put(self: *@This(), key: K, value: V) void {
            if (self.getIndex(key)) |i| {
                self.values[i] = value;
            }

            const key_item: []const K = &.{key};
            self.keys = self.keys ++ key_item;
            const value_item: []const V = &.{value};
            self.values = self.values ++ value_item;
        }

        pub fn has(self: @This(), key: K) bool {
            return self.getIndex(key) != null;
        }

        pub fn getIndex(self: @This(), key: K) ?usize {
            for (self.keys, 0..) |k, i| if (std.mem.eql(u8, k, key)) return i;
            return null;
        }

        pub fn get(self: *@This(), key: K) ?V {
            if (self.getIndex(key)) |i| {
                return self.values[i];
            }

            return null;
        }
    };
}
