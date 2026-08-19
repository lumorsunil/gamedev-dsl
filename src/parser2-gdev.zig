const std = @import("std");
const core = @import("parser2.zig");
const ParseError = core.ParseError;
const ParseContext = core.ParseContext;
const Parser = core.Parser;
const ct = @import("comptime2.zig");
const Node = ct.Node;
const Token = std.zig.Token;

pub fn parse(source: [:0]const u8) ParseError!Node {
    var ctx = ParseContext.init(source);

    return main_parser.run(&ctx);
}

const main_parser = parse_expressions;

const parse_expressions: Parser(Node) = .init(parseExpressions);

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

const parse_expression = Parser(Node).init(parseExpression);

fn parseExpression(ctx: *ParseContext) ParseError!Node {
    return core.oneOf(.{
        parse_binding,
        parse_identifier,
        parse_number_literal,
    }).run(ctx);
}

const parse_number_literal = Parser(Node).init(parseNumberLiteral);

fn parseNumberLiteral(ctx: *ParseContext) ParseError!Node {
    const token = try ctx.expect(.number_literal);
    const lexeme = ctx.lexeme(token.loc);

    return switch (std.zig.parseNumberLiteral(lexeme)) {
        .failure => unreachable,
        .big_int => ParseError.NotSupported,
        .float => .literal(std.fmt.parseFloat(f32, lexeme) catch unreachable),
        .int => |int| .literal(int),
    };
}

const parse_identifier: Parser(Node) = core.map(
    core.sequence(.{
        core.token(.identifier),
        core.get_context,
    }),
    parseIdentifierMap,
);

fn parseIdentifierMap(result: struct { Token, *ParseContext }) Node {
    const token, const ctx = result;
    return .identifier(ctx.lexeme(token.loc));
}

const parse_binding: Parser(Node) = core.map(
    core.sequence(.{
        core.get_context,
        core.token(.keyword_const),
        core.token(.identifier),
        core.token(.equal),
        parse_expression,
    }),
    parseBindingMap,
);

fn parseBindingMap(result: struct { *ParseContext, Token, Token, Token, Node }) Node {
    const ctx, _, const identifier_token, _, const node = result;
    const identifier = ctx.lexeme(identifier_token.loc);
    return .binding(identifier, node);
}
