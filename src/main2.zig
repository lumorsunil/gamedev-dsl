const std = @import("std");
const ct = @import("comptime2.zig");
const allocator_mod = @import("allocator.zig");

const Result = union(enum) {
    success: struct {
        tokens: []const std.zig.Token.Tag,
        ast: ct.Node,
        ir: ct.IRNode,
        ctx: ct.CompilationContext,
    },
    err: struct {
        log: []const []const u8,
        diagnostics: []const ct.ParseContext.Diagnostic,
    },
};

pub fn main(init: std.process.Init) !void {
    allocator_mod.allocator = init.gpa;

    const compilation_result: Result = comptime brk: {
        @setEvalBranchQuota(10000);
        const file_source = @embedFile("game.gdev");
        const tokens = ct.tokenize(file_source);
        const parse_result = ct.parse2(file_source);

        if (parse_result.ast) |ast| {
            var c_ctx: ct.CompilationContext = .empty;
            const result = ct.compile(&c_ctx, ast);
            break :brk .{ .success = .{
                .tokens = tokens,
                .ast = ast,
                .ir = result,
                .ctx = c_ctx,
            } };
        } else {
            break :brk .{ .err = .{
                .log = parse_result.ctx.log_,
                .diagnostics = parse_result.ctx.diagnostics,
            } };
        }
    };

    switch (compilation_result) {
        .success => |result| {
            std.log.debug("tokens: {any}", .{result.tokens});
            std.log.debug("ast: {f}", .{result.ast});

            var ir_ctx: ct.IRContext = .init(init.gpa);
            defer ir_ctx.deinit();
            const output = ct.evaluate(&ir_ctx, result.ir);

            std.log.debug("{any}: {s}", .{ output, @typeName(@TypeOf(output)) });
        },
        .err => |err| {
            std.log.err("compile error:", .{});

            for (err.log) |log| {
                std.log.err("{s}", .{log});
            }

            for (err.diagnostics) |diagnostic| {
                std.log.err("{f}", .{diagnostic});
            }
        },
    }
}
