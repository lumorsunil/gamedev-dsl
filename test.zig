const std = @import("std");

fn f() void {
    std.log.debug("f", .{});
}

pub fn main(init: std.process.Init) !void {}
