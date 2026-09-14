const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const IRNode = @import("evaluate.zig").IRNode;
const IRInstruction = @import("effect-vm.zig").IRInstruction;
const VM = @import("effect-vm.zig").VM;

pub const parse = @import("parser-gdev.zig").parse;
pub const parse2 = @import("parser2-gdev.zig").parse;
pub const ParseContext = @import("parser2.zig").ParseContext;

pub fn tokenize(source: [:0]const u8) []const std.zig.Token.Tag {
    var tokens: []const std.zig.Token.Tag = &.{};
    var tokenizer = std.zig.Tokenizer.init(source);

    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        const item: []const std.zig.Token.Tag = &.{token.tag};
        tokens = tokens ++ item;
    }

    return tokens;
}

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

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self.node_type) {
            .literal_ => |literal_| try writer.print("literal{{ {}: {} }}", .{ literal_.get(), literal_.type }),
            .identifier_ => |identifier_| try writer.print("identifier{{ {s} }}", .{identifier_.identifier}),
            .binding_ => |binding_| try writer.print("binding{{ {s} = {f} }}", .{ binding_.identifier, binding_.target.* }),
            .sequence_ => |sequence_| {
                inline for (sequence_) |node| {
                    try writer.print("{f}\n", .{node});
                }
            },
        }
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
    const ir_node = compile(ctx, binding.target.*);
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
