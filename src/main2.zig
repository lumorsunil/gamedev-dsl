const std = @import("std");

const ct = @import("comptime2.zig");

const source = ct.Node.sequence(&.{
    .literal(1),
    .literal(2),
    .literal(3),
});

const source2 = ct.Node.sequence(&.{
    .binding("hello", .literal(5)),
    .identifier("hello"),
});

pub fn main(init: std.process.Init) !void {
    const compilation_result = comptime brk: {
        const file_source = @embedFile("game.gdev");
        const ast = ct.parse(file_source) catch |err| {
            @compileError("error parsing code: " ++ @errorName(err));
        };

        var c_ctx: ct.CompilationContext = .empty;
        const result = ct.compile(&c_ctx, ast);
        break :brk .{
            .ir = result,
            .ctx = c_ctx,
        };
    };

    var ir_ctx: ct.IRContext = .init(init.gpa);
    defer ir_ctx.deinit();
    const output = ct.evaluate(&ir_ctx, compilation_result.ir);

    std.log.debug("{any}: {s}", .{ output, @typeName(@TypeOf(output)) });
}
