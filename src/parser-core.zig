const std = @import("std");
const Value = @import("value.zig").Value;

pub const ParseContext = struct {
    source: [:0]const u8,
    tokenizer: std.zig.Tokenizer,

    pub fn init(source: [:0]const u8) @This() {
        return .{ .source = source, .tokenizer = .init(source) };
    }

    pub fn lexeme(self: @This(), loc: std.zig.Token.Loc) []const u8 {
        return self.source[loc.start..loc.end];
    }

    pub fn expect(self: *@This(), tag: std.zig.Token.Tag) ParseError!std.zig.Token {
        const tok = self.tokenizer.next();

        if (tok.tag != tag) return ParseError.UnexpectedToken;

        return tok;
    }

    pub fn peek(self: *@This()) std.zig.Token {
        var tokenizer = self.tokenizer;
        return tokenizer.next();
    }

    pub fn snapshot(self: @This()) Snapshot {
        return .init(self);
    }

    pub const Snapshot = struct {
        tokenizer_index: usize,

        pub fn init(ctx: ParseContext) @This() {
            return .{
                .tokenizer_index = ctx.tokenizer.index,
            };
        }

        pub fn restore(self: @This(), ctx: *ParseContext) void {
            ctx.tokenizer.index = self.tokenizer_index;
        }
    };
};

fn ParseFunction(comptime T: type) type {
    return *const fn (*ParseContext) ParseError!T;
}

fn PayloadType(f: anytype) type {
    const return_type = @typeInfo(@TypeOf(f)).@"fn".return_type orelse void;
    return @typeInfo(return_type).error_union.payload;
}

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedExpression,
    NotSupported,
};

pub const Parser = struct {
    f: *const anyopaque,
    payload_type: type,

    pub fn init(f: anytype) @This() {
        return .{ .f = f, .payload_type = PayloadType(f) };
    }

    pub fn get(self: @This()) ParseFunction(self.payload_type) {
        return @ptrCast(self.f);
    }

    pub fn run(self: @This(), ctx: *ParseContext) ParseError!self.payload_type {
        return self.get()(ctx);
    }
};

fn tryParse(parser: Parser) Parser {
    return .init(
        struct {
            fn tryParse_(ctx: *ParseContext) ParseError!?parser.payload_type {
                const snapshot = ctx.snapshot();
                const maybe_result = parser.run(ctx);

                if (maybe_result) |result| {
                    return result;
                } else |_| {
                    snapshot.restore(ctx);
                    return null;
                }
            }
        }.tryParse_,
    );
}

pub fn oneOf(parsers: anytype) Parser {
    var payload_type = parsers.@"0".payload_type;
    for (parsers) |parser| {
        if (payload_type != parser.payload_type) {
            payload_type = Value;
            break;
        }
    }
    const payload_type_ = payload_type;

    return .init(
        struct {
            fn oneOf_(ctx: *ParseContext) ParseError!payload_type_ {
                for (parsers) |parser| {
                    const f = tryParse(parser).get();
                    if (try f(ctx)) |result| {
                        if (payload_type_ == Value) {
                            return .init(result);
                        } else {
                            return result;
                        }
                    }
                }

                return ParseError.UnexpectedExpression;
            }
        }.oneOf_,
    );
}

fn SequencePayload(parsers: anytype) type {
    var field_types: []const type = &.{};

    for (parsers) |parser| {
        const item: []const type = &.{parser.payload_type};
        field_types = field_types ++ item;
    }

    return @Tuple(field_types);
}

pub fn sequence(parsers: anytype) Parser {
    return .init(struct {
        pub fn sequence_(ctx: *ParseContext) ParseError!SequencePayload(parsers) {
            var payloads: SequencePayload(parsers) = undefined;

            for (parsers, &payloads) |parser, *payload| {
                payload.* = try parser.run(ctx);
            }

            return payloads;
        }
    });
}

pub fn token(tag: std.zig.Token.Tag) Parser {
    return .init(struct {
        fn token_(ctx: *ParseContext) ParseError!std.zig.Token {
            return ctx.expect(tag);
        }
    }.token_);
}

fn ReturnType(f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type orelse void;
}

pub fn map(parser: Parser, f: anytype) Parser {
    return .init(struct {
        fn map_(ctx: *ParseContext) ParseError!ReturnType(f) {
            const a = try parser.run(ctx);
            return f(a);
        }
    }.map_);
}

pub fn pure(value: anytype) Parser {
    return .init(struct {
        fn pure_(_: *ParseContext) ParseError!@TypeOf(value) {
            return value;
        }
    }.pure_);
}

pub fn bind(parser: Parser, f: anytype) Parser {
    const M = ReturnType(f);
    if (M != Parser) @compileError("expected return type Parser, got " ++ @typeName(M));

    return .init(struct {
        fn bind_(ctx: *ParseContext) ParseError!Value {
            const a = try parser.run(ctx);
            const bind_parser = f(a);
            return .init(bind_parser.run(ctx));
        }
    }.bind_);
}
