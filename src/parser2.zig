const std = @import("std");
const Value = @import("value.zig").Value;
const Token = std.zig.Token;

const core = @This();

const ComptimeWriter = struct {
    written: []const u8 = &.{},

    pub fn init() @This() {
        return .{};
    }

    pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) void {
        self.writeAll(std.fmt.comptimePrint(fmt, args));
    }

    pub fn writeAll(self: *@This(), message: []const u8) void {
        self.written = self.written ++ message;
    }
};

pub const ParseContext = struct {
    source: [:0]const u8,
    tokenizer: std.zig.Tokenizer,
    diagnostics: []const Diagnostic = &.{},
    log_: []const []const u8 = &.{},
    depth: usize = 0,
    snapshot_id: usize = 0,

    pub fn init(source: [:0]const u8) @This() {
        return .{ .source = source, .tokenizer = .init(source) };
    }

    pub fn lexeme(self: @This(), loc: Token.Loc) []const u8 {
        return self.source[loc.start..loc.end];
    }

    pub fn expect(self: *@This(), tag: Token.Tag) ParseError!Token {
        const tok = self.tokenizer.next();

        if (tok.tag != tag) return ParseError.UnexpectedToken;

        return tok;
    }

    pub fn peek(self: *@This()) Token {
        var tokenizer = self.tokenizer;
        return tokenizer.next();
    }

    pub fn consume(self: *@This(), n_tokens: usize) void {
        for (0..n_tokens) |_| _ = self.tokenizer.next();
    }

    pub fn snapshot(self: *@This()) Snapshot {
        self.snapshot_id += 1;
        self.log("snapshot({}) created", .{self.snapshot_id});
        return .init(self.*);
    }

    pub fn log(comptime self: *@This(), comptime fmt: []const u8, args: anytype) void {
        // @compileLog("log: " ++ @typeName(@TypeOf(self)));
        self.logWriteAll(std.fmt.comptimePrint(fmt, args));
    }

    pub fn logWriteAll(comptime self: *@This(), message: []const u8) void {
        if (comptime @TypeOf(self) == type) {
            // @compileLog(self);
            return;
        }
        var writer = ComptimeWriter.init();
        // @compileLog("logWriteAll: " ++ @typeName(@TypeOf(self)));
        for (0..self.depth) |_| writer.writeAll(" ");
        writer.writeAll(message);
        const item: []const []const u8 = &.{writer.written};
        // const indentation = " " ** self.depth;
        // const item: []const []const u8 = &.{indentation ++ message};
        self.log_ = self.log_ ++ item;
    }

    pub fn report(self: *@This(), comptime diagnostic: Diagnostic) void {
        self.log("diagnostic reported: {f}", .{diagnostic});

        const item: []const Diagnostic = &.{diagnostic};
        self.diagnostics = self.diagnostics ++ item;
    }

    pub fn report_(
        self: *@This(),
        level: Diagnostic.Level,
        comptime fmt: []const u8,
        args: anytype,
        tok: Token,
    ) void {
        self.report(.init(
            self.source,
            level,
            fmt,
            args,
            .fromToken(self.source, tok),
            self.depth,
        ));
    }

    pub const Snapshot = struct {
        id: usize,
        tokenizer_index: usize,
        n_diagnostics: usize,
        depth: usize,

        pub fn init(ctx: ParseContext) @This() {
            return .{
                .id = ctx.snapshot_id,
                .tokenizer_index = ctx.tokenizer.index,
                .n_diagnostics = ctx.diagnostics.len,
                .depth = ctx.depth,
            };
        }

        pub fn restore(self: @This(), ctx: *ParseContext) void {
            ctx.log("snapshot({}) restored", .{self.id});
            ctx.tokenizer.index = self.tokenizer_index;
            ctx.diagnostics = ctx.diagnostics[0..self.n_diagnostics];
            ctx.depth = self.depth;
        }
    };

    pub const Loc = struct {
        line: usize,
        column: usize,
        source_line: []const u8,
        line_start_index: usize,

        pub fn init(source: []const u8, index: usize) @This() {
            const loc = std.zig.findLineColumn(source, index);
            return .{
                .line = loc.line,
                .column = loc.column,
                .source_line = loc.source_line,
                .line_start_index = index - loc.column,
            };
        }

        pub fn endIndex(self: @This()) usize {
            return self.line_start_index + self.source_line.len;
        }
    };

    pub const Span = struct {
        start: Loc,
        end: Loc,

        pub fn init(start: Loc, end: Loc) @This() {
            return .{ .start = start, .end = end };
        }

        pub fn fromToken(source: []const u8, tok: Token) @This() {
            return .init(
                .init(source, tok.loc.start),
                .init(source, tok.loc.end),
            );
        }

        const LineIterator = struct {
            it: std.mem.SplitIterator(u8, .scalar),
            index: usize = 0,
            start_line: isize,
            end_line: isize,

            pub fn init(it: std.mem.SplitIterator(u8, .scalar), start_line: isize, end_line: isize) @This() {
                return .{ .it = it, .start_line = start_line, .end_line = end_line };
            }

            pub fn next(self: *@This()) ?Line {
                const source_line = self.it.next() orelse return null;
                defer self.index += 1;

                return .{
                    .source_line = source_line,
                    .type = if (self.index >= self.start_line and self.index <= self.end_line) .span else .extra,
                };
            }

            pub const Line = struct {
                source_line: []const u8,
                type: Type,

                pub const Type = enum { extra, span };
            };
        };

        pub fn lineIterator(self: @This(), source: []const u8) LineIterator {
            const span_start = self.start.line_start_index;
            const span_end = self.end.endIndex();

            const n_lines_extra = 2;
            var start = span_start;
            var end = span_end;
            var start_line: isize = 0;

            for (0..n_lines_extra) |_| {
                start -|= 1;
                var loc = std.zig.findLineColumn(source, start);
                start_line = @intCast(self.start.line);
                start_line -= @intCast(loc.line);
                start -|= loc.column;

                end +|= 1;
                end = @min(end, source.len);
                loc = std.zig.findLineColumn(source, end);
                end +|= loc.source_line.len;
            }
            var end_line: isize = @intCast(start_line);
            end_line += @intCast(self.end.line - self.start.line);

            const truth = source[start..end];

            return .init(std.mem.splitScalar(u8, truth, '\n'), start_line, end_line);
        }
    };

    pub const Diagnostic = struct {
        level: Level,
        message: []const u8,
        span: Span,
        source: []const u8,
        depth: usize,

        pub fn init(
            source: []const u8,
            level: Level,
            comptime fmt: []const u8,
            args: anytype,
            span: Span,
            depth: usize,
        ) @This() {
            return .{
                .level = level,
                .message = std.fmt.comptimePrint(fmt, args),
                .span = span,
                .source = source,
                .depth = depth,
            };
        }

        pub fn lineIterator(self: @This()) Span.LineIterator {
            return self.span.lineIterator(self.source);
        }

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("{t}: {s}\n", .{ self.level, self.message });

            const terminal = std.Io.Terminal{ .writer = writer, .mode = .escape_codes };

            var it = self.lineIterator();
            var n_line = self.span.start.line;
            while (it.next()) |line| : (n_line += 1) {
                switch (line.type) {
                    .extra => try writer.print("  {s}\n", .{line.source_line}),
                    .span => {
                        try writer.writeAll("> ");

                        if (self.span.start.line == self.span.end.line) {
                            const left_part = line.source_line[0..self.span.start.column];
                            const middle_part = line.source_line[self.span.start.column..self.span.end.column];
                            const right_part = line.source_line[self.span.end.column..];
                            try writer.print("{s}", .{left_part});
                            terminal.setColor(.yellow) catch {};
                            try writer.print("{s}", .{middle_part});
                            terminal.setColor(.reset) catch {};
                            try writer.print("{s}\n", .{right_part});
                        } else if (n_line == self.span.start.line) {
                            const left_part = line.source_line[0..self.span.start.column];
                            const right_part = line.source_line[self.span.start.column..];
                            try writer.print("{s}", .{left_part});
                            terminal.setColor(.yellow) catch {};
                            try writer.print("{s}\n", .{right_part});
                            terminal.setColor(.reset) catch {};
                        } else if (n_line == self.span.end.line) {
                            const left_part = line.source_line[0..self.span.end.column];
                            const right_part = line.source_line[self.span.end.column..];
                            terminal.setColor(.yellow) catch {};
                            try writer.print("{s}", .{left_part});
                            terminal.setColor(.reset) catch {};
                            try writer.print("{s}\n", .{right_part});
                        } else {
                            terminal.setColor(.yellow) catch {};
                            try writer.print("{s}\n", .{line.source_line});
                            terminal.setColor(.reset) catch {};
                        }
                    },
                }
            }
        }

        pub const Level = enum { info, warn, err };
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
        label: []const u8,
        options: Options,

        pub const Payload = T;
        pub const Options = struct {
            show_in_log: bool = false,
        };

        pub fn init(f: anytype, label_: []const u8, options: Options) @This() {
            return .{
                .f = f,
                .label = label_,
                .options = options,
            };
        }

        pub fn run(self: @This(), ctx: *ParseContext) ParseError!T {
            return self.f(ctx);
        }

        pub fn pure(value: T) @This() {
            return pureOrErr(value);
        }

        pub fn err(err_: ParseError) @This() {
            return pureOrErr(err_);
        }

        fn pureOrErr(value: anytype) @This() {
            return .init(struct {
                fn pureOrErr_(_: *ParseContext) ParseError!T {
                    return value;
                }
            }.pureOrErr_, "pureOrErr", .{});
        }
    };
}

fn tryParse(parser: anytype) Parser(?ParserPayload(parser)) {
    return .init(struct {
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
    }.tryParse_, @src().fn_name, .{});
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
            // comptime {
            //     var labels = ComptimeWriter.init();
            //     for (parsers) |parser| labels.print("{s}", .{parser.label});
            //     ctx.log(@src().fn_name ++ " ({s})", .{labels.written});
            // }
            ctx.depth += 1;

            for (parsers) |parser| {
                const parser_try = tryParse(parser);
                if (try parser_try.run(ctx)) |result| {
                    ctx.depth -= 1;

                    if (OneOfPayload(parsers) == Value) {
                        return .init(result);
                    } else {
                        return result;
                    }
                }
            }

            return ParseError.UnexpectedExpression;
        }
    }.oneOf_, @src().fn_name, .{});
}

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
    }.sequence_, @src().fn_name, .{});
}

pub fn token(tag: Token.Tag) Parser(Token) {
    return .init(struct {
        fn token_(ctx: *ParseContext) ParseError!Token {
            return ctx.expect(tag);
        }
    }.token_, @src().fn_name, .{});
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
    }.map_, @src().fn_name, .{});
}

pub fn pure(value: anytype) Parser(@TypeOf(value)) {
    return .pure(value);
}

// fmap :: (Monad m) => m a -> (a -> b) -> m b
// (>>=) = bind :: (Monad m) => m a -> (a -> m b) -> m b
// return :: (Monad m) => a -> m a
// fmap ma f = bind ma (\a -> return a)
pub fn bind(parser: anytype, f: anytype) ReturnType(f) {
    return .init(struct {
        fn bind_(ctx: *ParseContext) ParseError!ParserPayload(ReturnType(f)) {
            const a = try parser.run(ctx);
            const bind_parser = f(a);
            return bind_parser.run(ctx);
        }
    }.bind_, @src().fn_name, .{});
}

pub fn mkParser(f: anytype) Parser(PayloadType(f)) {
    return .init(f);
}

pub const get_context: Parser(*ParseContext) = .init(struct {
    fn getContext_(ctx: *ParseContext) ParseError!*ParseContext {
        return ctx;
    }
}.getContext_, "getContext", .{});

pub fn handleError(parser: anytype, handler: *const fn (comptime *ParseContext, Token, ParseError) void) Parser(ParserPayload(parser)) {
    return .init(struct {
        fn handleError_(ctx: *ParseContext) ParseError!ParserPayload(parser) {
            const tok = ctx.peek();

            return parser.run(ctx) catch |err| {
                handler(ctx, tok, err);
                return err;
            };
        }
    }.handleError_, @src().fn_name, .{});
}

pub fn simpleErrorHandler(message: []const u8) *const fn (comptime *ParseContext, Token, ParseError) void {
    return struct {
        fn errorHandler(comptime ctx: *ParseContext, tok: Token, err: ParseError) void {
            ctx.report_(.err, "{}: {s}", .{ err, message }, tok);
        }
    }.errorHandler;
}

pub fn handleErrorSimple(parser: anytype, message: []const u8) Parser(ParserPayload(parser)) {
    return handleError(parser, simpleErrorHandler(message));
}

pub fn label(label_: []const u8, parser: anytype) Parser(ParserPayload(parser)) {
    return .init(
        struct {
            fn label__(ctx: *ParseContext) ParseError!ParserPayload(parser) {
                // TODO: find another way to do this (currently causes SEGV)
                // @compileLog("here");
                // @compileLog("label: " ++ @typeName(@TypeOf(ctx)));
                ctx.logWriteAll(label_);
                ctx.depth += 1;
                defer ctx.depth -= 1;
                return parser.run(ctx);
            }
        }.label__,
        label_,
        .{ .show_in_log = true },
    );
}
