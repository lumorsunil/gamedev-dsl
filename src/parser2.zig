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

fn ParserPayload(parser: anytype) type {
    if (comptime @TypeOf(parser) == type) {
        return parser.Payload;
    } else {
        return @TypeOf(parser).Payload;
    }
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

pub fn Parser(comptime T: type) type {
    return struct {
        f: ParseFunction(T),

        pub const Payload = T;

        pub fn init(f: anytype) @This() {
            return .{ .f = f };
        }

        pub fn run(self: @This(), ctx: *ParseContext) ParseError!T {
            return self.f(ctx);
        }
    };
}

fn tryParse(parser: anytype) Parser(?ParserPayload(parser)) {
    return .init(
        struct {
            fn tryParse_(ctx: *ParseContext) ParseError!?ParserPayload(parser) {
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

fn OneOfPayload(parsers: anytype) type {
    var payload_type = ParserPayload(parsers.@"0");
    for (parsers) |parser| {
        if (payload_type != ParserPayload(parser)) {
            payload_type = Value;
            break;
        }
    }
    const payload_type_ = payload_type;

    return payload_type_;
}

pub fn oneOf(parsers: anytype) Parser(OneOfPayload(parsers)) {
    return .init(struct {
        fn oneOf_(ctx: *ParseContext) ParseError!OneOfPayload(parsers) {
            for (parsers) |parser| {
                const parser_try = tryParse(parser);
                if (try parser_try.run(ctx)) |result| {
                    if (OneOfPayload(parsers) == Value) {
                        return .init(result);
                    } else {
                        return result;
                    }
                }
            }

            return ParseError.UnexpectedExpression;
        }
    }.oneOf_);
}

// pub fn deferred(getParser: *const fn () Parser) Parser {
//     return .init(struct {
//         fn deferred_(ctx: *ParseContext) ParseError!parser.payload_type {
//             const parser = getParser();
//             return parser.run(ctx);
//         }
//     }.deferred_);
// }

fn SequencePayload(parsers: anytype) type {
    var field_types: []const type = &.{};

    for (parsers) |parser| {
        const item: []const type = &.{ParserPayload(parser)};
        field_types = field_types ++ item;
    }

    return @Tuple(field_types);
}

pub fn sequence(parsers: anytype) Parser(SequencePayload(parsers)) {
    return .init(struct {
        pub fn sequence_(ctx: *ParseContext) ParseError!SequencePayload(parsers) {
            var payloads: SequencePayload(parsers) = undefined;

            inline for (parsers, &payloads) |parser, *payload| {
                payload.* = try parser.run(ctx);
            }

            return payloads;
        }
    }.sequence_);
}

pub fn token(tag: std.zig.Token.Tag) Parser(std.zig.Token) {
    return .init(struct {
        fn token_(ctx: *ParseContext) ParseError!std.zig.Token {
            return ctx.expect(tag);
        }
    }.token_);
}

fn ReturnType(f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type orelse void;
}

pub fn map(parser: anytype, f: anytype) Parser(ReturnType(f)) {
    return .init(struct {
        fn map_(ctx: *ParseContext) ParseError!ReturnType(f) {
            const a = try parser.run(ctx);
            return f(a);
        }
    }.map_);
}

pub fn pure(value: anytype) Parser(@TypeOf(value)) {
    return .init(struct {
        fn pure_(_: *ParseContext) ParseError!@TypeOf(value) {
            return value;
        }
    }.pure_);
}

pub fn bind(parser: anytype, f: anytype) ReturnType(f) {
    return .init(struct {
        fn bind_(ctx: *ParseContext) ParseError!ParserPayload(ReturnType(f)) {
            const a = try parser.run(ctx);
            const bind_parser = f(a);
            return .init(bind_parser.run(ctx));
        }
    }.bind_);
}

pub fn mkParser(f: anytype) Parser(PayloadType(f)) {
    return .init(f);
}

pub const get_context: Parser(*ParseContext) = .init(struct {
    fn getContext_(ctx: *ParseContext) ParseError!*ParseContext {
        return ctx;
    }
}.getContext_);
