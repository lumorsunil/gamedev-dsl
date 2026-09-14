const std = @import("std");
const Value = @import("value.zig").Value;
const allocator = @import("allocator.zig").allocator;

pub const IRNode = struct {
    node_type: IRNodeType,
    type: type,

    pub fn init(type_: type, node_type: IRNodeType) @This() {
        return .{ .node_type = node_type, .type = type_ };
    }

    pub fn literal(value: anytype) @This() {
        return .init(@TypeOf(value), .{ .literal_ = .init(value) });
    }

    pub fn identifier(type_: type, identifier_: []const u8) @This() {
        return .init(type_, .{ .identifier_ = .{ .identifier = identifier_ } });
    }

    pub fn binding(identifier_: []const u8, expr: IRNode) @This() {
        return .init(void, .{ .binding_ = .{ .identifier = identifier_, .expr = &expr } });
    }

    pub fn sequence(body: []const IRNode, last: IRNode) @This() {
        return .init(last.type, .{ .sequence_ = .{ .body = body, .last = &last } });
    }

    pub const Literal = Value;

    pub const Identifier = struct {
        identifier: []const u8,
    };

    pub const Binding = struct {
        identifier: []const u8,
        expr: *const IRNode,
    };

    pub const Sequence = struct {
        body: []const IRNode,
        last: *const IRNode,
    };

    pub const IRNodeType = union(enum) {
        literal_: Literal,
        identifier_: Identifier,
        binding_: Binding,
        sequence_: Sequence,
    };
};

pub fn evaluate(ctx: *VM, comptime node: IRNode) node.type {
    return switch (comptime node.node_type) {
        .literal_ => |literal| evaluateLiteral(node.type, ctx, literal),
        .binding_ => |binding| evaluateBinding(ctx, binding),
        .identifier_ => |identifier| evaluateIdentifier(node.type, ctx, identifier),
        .sequence_ => |sequence| evaluateSequence(ctx, sequence),
    };
}

fn evaluateLiteral(comptime T: type, _: *VM, comptime literal: IRNode.Literal) T {
    return literal.get();
}

fn evaluateBinding(ctx: *VM, comptime binding: IRNode.Binding) void {
    const value = evaluate(ctx, binding.expr.*);
    ctx.handleBind(binding.identifier, value);
}

fn evaluateIdentifier(
    comptime T: type,
    ctx: *VM,
    comptime identifier: IRNode.Identifier,
) T {
    return ctx.frames.get(T, identifier.identifier) orelse unreachable;
}

fn evaluateSequence(ctx: *VM, comptime sequence: IRNode.Sequence) sequence.last.type {
    inline for (sequence.body) |node| {
        _ = evaluate(ctx, node);
    }
    return evaluate(ctx, sequence.last.*);
}
