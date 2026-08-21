const std = @import("std");
const core = @import("parser2.zig");
const ParseError = core.ParseError;
const ParseContext = core.ParseContext;
const Parser = core.Parser;
const ct = @import("comptime2.zig");
const Node = ct.Node;
const Token = std.zig.Token;

pub const ParseResult = struct {
    ast: ?Node,
    ctx: ParseContext,
};

pub fn parse(source: [:0]const u8) ParseResult {
    var ctx = ParseContext.init(source);

    const ast = main_parser.run(&ctx) catch null;

    return .{
        .ast = ast,
        .ctx = ctx,
    };
}

const main_parser = core.label("mainParser", parse_expressions);

const parse_expressions: Parser(Node) = .init(
    parseExpressions,
    "parseExpressions",
    .{ .show_in_log = true },
);

fn parseExpressions(ctx: *ParseContext) ParseError!Node {
    var nodes: []const Node = &.{};

    while (true) {
        if (ctx.peek().tag == .eof) break;
        const expr = try parse_expression.run(ctx);
        _ = try ctx.expect(.semicolon);

        const item: []const Node = &.{expr};
        nodes = nodes ++ item;
    }

    if (nodes.len == 0) return .noop;
    if (nodes.len == 1) return nodes[0];

    return .sequence(nodes);
}

const parse_expression = Parser(Node).init(
    parseExpression,
    "parseExpression",
    .{ .show_in_log = true },
);

fn parseExpression(ctx: *ParseContext) ParseError!Node {
    return core.label("parseExpression", core.handleErrorSimple(core.oneOf(.{
        parse_binding,
        parse_discard,
        parse_identifier,
        parse_number_literal,
    }), "expected expression")).run(ctx);
}

const parse_discard = core.label("parseDiscard", core.bind(
    parse_identifier_s,
    parseDiscardBind,
));

fn parseDiscardBind(identifier: []const u8) Parser(Node) {
    if (std.mem.eql(u8, identifier, "_")) {
        return .pure(.identifier(identifier));
    } else {
        return core.handleErrorSimple(
            Parser(Node).err(ParseError.UnexpectedToken),
            "expected discard",
        );
    }
}

const parse_number_literal = core.handleErrorSimple(
    Parser(Node).init(parseNumberLiteral, "parseNumberLiteral", .{ .show_in_log = true }),
    "expected number literal",
);

fn parseNumberLiteral(ctx: *ParseContext) ParseError!Node {
    const sign = if (ctx.peek().tag == .minus) -1 else 1;
    if (sign == -1) ctx.consume(1);
    const token = try ctx.expect(.number_literal);
    const lexeme = ctx.lexeme(token.loc);

    return switch (std.zig.parseNumberLiteral(lexeme)) {
        .failure => unreachable,
        .big_int => ParseError.NotSupported,
        .float => .literal((std.fmt.parseFloat(f32, lexeme) catch unreachable) * sign),
        .int => |int| .literal(@as(i64, @intCast(int)) * sign),
    };
}

const parse_identifier_s: Parser([]const u8) = core.map(
    core.sequence(.{
        core.token(.identifier),
        core.get_context,
    }),
    parseIdentifierSMap,
);

fn parseIdentifierSMap(result: struct { Token, *ParseContext }) []const u8 {
    const token, const ctx = result;
    return ctx.lexeme(token.loc);
}

const parse_identifier: Parser(Node) = core.label("parseIdentifier", core.map(
    parse_identifier_s,
    Node.identifier,
));

const parse_binding: Parser(Node) = core.label("parseBinding", core.map(
    core.sequence(.{
        core.token(.keyword_const),
        parse_identifier,
        core.token(.equal),
        parse_expression,
    }),
    parseBindingMap,
));

fn parseBindingMap(result: struct { Token, Node, Token, Node }) Node {
    _, const identifier_node, _, const node = result;
    return .binding(identifier_node.node_type.identifier_.identifier, node);
}
