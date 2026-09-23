const std = @import("std");
const Allocator = std.mem.Allocator;

pub var allocator: Allocator = undefined;
pub var page: Allocator = undefined;
