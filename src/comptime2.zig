const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;

pub const parse = @import("parser-gdev.zig").parse;

const ComptimeScope = @import("comptime-scope.zig").ComptimeScope;

pub const CompilationContext = struct {
    scope: ComptimeScope(Node) = .empty,
    type_ctx: TypeCompilationContext = .empty,

    pub const empty = @This(){};
};

pub const TypeCompilationContext = struct {
    scope: ComptimeScope(type) = .empty,

    pub const empty = @This(){};
};

pub const Node = struct {
    node_type: NodeType,

    pub fn init(node_type: NodeType) @This() {
        return .{ .node_type = node_type };
    }

    pub fn literal(value: anytype) @This() {
        return .init(.{ .literal_ = .init(value) });
    }

    pub fn binding(identifier_: []const u8, target: Node) @This() {
        return .init(.{ .binding_ = .{ .identifier = identifier_, .target = &target } });
    }

    pub fn identifier(identifier_: []const u8) @This() {
        return .init(.{ .identifier_ = .{ .identifier = identifier_ } });
    }

    pub fn sequence(sequence_: []const Node) @This() {
        return .init(.{ .sequence_ = sequence_ });
    }

    pub const NodeType = union(enum) {
        literal_: Literal,
        binding_: Binding,
        identifier_: Identifier,
        sequence_: Sequence,
    };

    pub const Literal = Value;

    pub const Binding = struct {
        identifier: []const u8,
        target: *const Node,
    };

    pub const Identifier = struct {
        identifier: []const u8,
    };

    pub const Sequence = []const Node;

    pub fn evaluateType(self: *@This(), ctx: *TypeCompilationContext) type {
        if (self.type) |T| return T;

        const T = switch (self.node_type) {
            .literal_ => |literal_| literal_.type,
            .binding_ => |binding_| binding_.target.evaluateType(ctx),
            .identifier_ => |identifier_| ctx.scope.get(identifier_.identifier).?,
            .sequence_ => |sequence_| sequence_[sequence_.len - 1].evaluateType(ctx),
        };

        self.type = T;

        return T;
    }
};

pub const RuntimeScope = struct {
    map: std.StringHashMap(V),

    pub const K = []const u8;
    pub const V = *anyopaque;

    pub fn init(allocator: Allocator) @This() {
        return .{ .map = .init(allocator) };
    }

    pub fn deinit(self: *@This()) void {
        self.map.deinit();
    }

    pub fn put(self: *@This(), key: K, value: anytype) void {
        const value_ptr = self.map.allocator.create(@TypeOf(value)) catch unreachable;
        value_ptr.* = value;
        self.map.put(key, value) catch unreachable;
    }

    pub fn get(self: *@This(), comptime T: type, key: K) ?T {
        const ptr = self.getPtr(T, key) orelse return null;
        return ptr.*;
    }

    pub fn getPtr(self: *@This(), comptime T: type, key: K) ?*T {
        return @as(?*T, @ptrCast(@alignCast(self.map.get(key))));
    }
};

pub const IRContext = struct {
    allocator: Allocator,
    scope: RuntimeScope,

    pub fn init(allocator: Allocator) @This() {
        return .{
            .allocator = allocator,
            .scope = .init(allocator),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.scope.deinit();
    }

    pub fn bind(self: *@This(), identifier: []const u8, value: anytype) void {
        const value_ptr = self.allocator.create(@TypeOf(value)) catch unreachable;
        value_ptr.* = value;
        self.scope.put(identifier, value_ptr);
    }
};

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
        return .init(expr.type, .{ .binding_ = .{ .identifier = identifier_, .expr = &expr } });
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

pub fn compile(ctx: *CompilationContext, node: Node) IRNode {
    return switch (node.node_type) {
        .literal_ => |literal| compileLiteral(ctx, literal),
        .binding_ => |binding| compileBinding(ctx, binding),
        .identifier_ => |identifier| compileIdentifier(ctx, identifier),
        .sequence_ => |sequence| compileSequence(ctx, sequence),
    };
}

fn compileLiteral(_: *CompilationContext, literal: Node.Literal) IRNode {
    return .literal(literal.get());
}

fn compileBinding(ctx: *CompilationContext, binding: Node.Binding) IRNode {
    if (ctx.type_ctx.scope.has(binding.identifier)) @compileError("duplicate identifier " ++ binding.identifier);
    const ir_node = compile(binding.target.*);
    ctx.type_ctx.scope.put(binding.identifier, ir_node.type);
    return .binding(binding.identifier, ir_node);
}

fn compileIdentifier(ctx: *CompilationContext, node_identifier: Node.Identifier) IRNode {
    const type_ = ctx.type_ctx.scope.get(node_identifier.identifier) orelse @compileError("undefined identifier " ++ node_identifier.identifier);
    return .identifier(type_, node_identifier.identifier);
}

fn compileSequence(ctx: *CompilationContext, sequence: Node.Sequence) IRNode {
    if (comptime sequence.len == 0) {
        return .noop;
    }

    if (comptime sequence.len == 1) {
        return compile(ctx, sequence[0]);
    }

    var body: []const IRNode = &.{};

    for (sequence[0 .. sequence.len - 1]) |node_| {
        const item: []const IRNode = &.{compile(ctx, node_)};
        body = body ++ item;
    }

    const last = compile(ctx, sequence[sequence.len - 1]);

    return .sequence(body, last);
}

pub fn evaluate(ctx: *IRContext, comptime node: IRNode) node.type {
    return switch (comptime node.node_type) {
        .literal_ => |literal| evaluateLiteral(node.type, ctx, literal),
        .binding_ => |binding| evaluateBinding(ctx, binding),
        .identifier_ => |identifier| evaluateIdentifier(ctx, identifier),
        .sequence_ => |sequence| evaluateSequence(ctx, sequence),
    };
}

fn evaluateLiteral(comptime T: type, _: *IRContext, comptime literal: IRNode.Literal) T {
    return literal.get();
}

fn evaluateBinding(ctx: *IRContext, comptime binding: IRNode.Binding) void {
    const value = evaluate(ctx, binding.expr.*);
    ctx.bind(binding.identifier, value);
}

fn evaluateIdentifier(
    comptime T: type,
    ctx: *IRContext,
    comptime identifier: IRNode.Identifier,
) T {
    return ctx.scope.get(T, identifier.identifier) orelse unreachable;
}

fn evaluateSequence(ctx: *IRContext, comptime sequence: IRNode.Sequence) sequence.last.type {
    inline for (sequence.body) |node| {
        _ = evaluate(ctx, node);
    }
    return evaluate(ctx, sequence.last.*);
}
