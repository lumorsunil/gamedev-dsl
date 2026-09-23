const std = @import("std");
const A = @import("allocator.zig");

pub const Tokenizer = struct {
    source: []const u8,
    index: usize = 0,
    line: usize = 1,
    column: usize = 1,
    marker: Location = .init(0, 1, 1),

    pub fn init(source: []const u8) @This() {
        return .{ .source = source };
    }

    pub fn tokenize(source: []const u8) ![]const Token {
        var tokens = std.ArrayList(Token).empty;
        var tokenizer = Tokenizer.init(source);

        while (tokenizer.next()) |token| {
            try tokens.append(A.allocator, token);
        }

        return tokens.toOwnedSlice(A.allocator);
    }

    pub fn mark(self: *@This()) void {
        self.marker = self.mkLoc();
    }

    pub fn next(self: *@This()) Error!?Token {
        const c = self.peekChar() orelse return null;
        self.mark();

        if (std.ascii.isAlphabetic(c)) {
            return self.nextKeyword() orelse
                self.nextIdentifier();
        } else if (std.ascii.isDigit(c)) {
            return self.nextNumber();
        } else return switch (c) {
            '"', '\'' => self.nextString(c),
            '/' => {
                self.consume(1);
                if (self.peekChar()) |p| {
                    if (p == '/') {
                        self.consumeUntil('\n');
                        return self.next();
                    }
                }
                return self.createFromMarker(.div);
            },
            ':' => self.matchString("::", .double_colon) orelse self.consumeAndReturn(1, .colon),
            '=' => self.consumeAndReturn(1, .equal),
            '[' => self.consumeAndReturn(1, .open_bracket),
            ']' => self.consumeAndReturn(1, .close_bracket),
            '{' => self.consumeAndReturn(1, .open_brace),
            '}' => self.consumeAndReturn(1, .close_brace),
            '(' => self.consumeAndReturn(1, .open_paren),
            ')' => self.consumeAndReturn(1, .close_paren),
            ',' => self.consumeAndReturn(1, .comma),
            '$' => self.consumeAndReturn(1, .dollar),
            '#' => self.matchString("#def", .@"#def") orelse
                self.matchString("#{", .hash_open_brace) orelse
                self.matchString("#}", .hash_close_brace) orelse
                self.consumeAndReturn(1, .hash),
            '&' => self.consumeAndReturn(1, .ampersand),
            '.' => self.matchString(".*", .dot_star) orelse self.consumeAndReturn(1, .dot),
            '+' => self.matchString("+=", .plus_equal) orelse
                self.matchString("++", .double_plus) orelse
                self.consumeAndReturn(1, .plus),
            '-' => {
                self.consume(1);
                if (self.peekChar()) |p| {
                    if (std.ascii.isDigit(p)) {
                        _ = self.nextNumber();
                        return self.createFromMarker(.number);
                    } else if (p == '=') {
                        self.consume(1);
                        return self.createFromMarker(.minus_equal);
                    }
                }
                return self.createFromMarker(.minus);
            },
            '*' => self.consumeAndReturn(1, .star),
            ' ', '\n', '\t' => {
                self.skipWhitespace();
                return self.next();
            },
            else => {
                std.log.err("unknown token", .{});
                var it = std.mem.splitScalar(u8, self.source, '\n');
                var i: usize = 0;
                var idx: usize = self.marker.index;
                while (it.next()) |line| {
                    i += 1;
                    if (self.marker.line == i) {
                        var buffer: [1024]u8 = undefined;
                        var writer = std.Io.Writer.fixed(&buffer);
                        _ = try writer.writeSplat(&.{" "}, idx);
                        try writer.writeByte('^');
                        std.log.err("at:\n{s}\n{s}", .{ line, writer.buffered() });
                        break;
                    }
                    idx -= line.len + 1;
                }
                return Error.UnknownToken;
            },
        };
    }

    pub fn skipWhitespace(
        self: *@This(),
    ) void {
        while (self.peekChar()) |c| switch (c) {
            ' ', '\t' => {
                self.column += 1;
                self.consume(1);
            },
            '\n' => {
                self.line += 1;
                self.column = 1;
                self.consume(1);
            },
            else => return,
        };
    }

    pub fn mkLoc(self: @This()) Location {
        return .init(self.index, self.line, self.column);
    }

    pub fn mkToken(
        self: @This(),
        tag: Token.Tag,
        start: Location,
        end: Location,
    ) Token {
        return .init(self.source, tag, start, end);
    }

    pub fn createFromMarker(
        self: @This(),
        tag: Token.Tag,
    ) Token {
        const start = self.marker;
        const end = self.mkLoc();
        return self.mkToken(tag, start, end);
    }

    pub fn matchString(self: *@This(), s: []const u8, tag: Token.Tag) ?Token {
        if (self.tryString(s)) {
            return self.createFromMarker(tag);
        } else {
            return null;
        }
    }

    pub fn consumeAndReturn(
        self: *@This(),
        n: usize,
        tag: Token.Tag,
    ) Token {
        const start = self.mkLoc();
        self.consume(n);
        const end = self.mkLoc();
        return self.mkToken(tag, start, end);
    }

    pub fn nextKeyword(self: *@This()) ?Token {
        for (Token.keywords) |keyword| {
            if (self.tryKeyword(keyword)) |tok| return tok;
        }

        return null;
    }

    fn tryString(self: *@This(), s: []const u8) bool {
        for (s) |c| {
            if (self.peekChar()) |p| {
                if (p == c) {
                    self.consume(1);
                    continue;
                }
            }
            self.index = self.marker.index;
            return false;
        }

        return true;
    }

    fn tryKeyword(self: *@This(), tag: Token.Tag) ?Token {
        var s = @tagName(tag);

        if (tag == .resume_) {
            s = "resume";
        }

        if (self.tryString(s)) {
            if (self.peekChar()) |after| if (isIdentifierSuccessor(after)) {
                return null;
            };
            return self.createFromMarker(tag);
        } else {
            return null;
        }
    }

    pub fn nextIdentifier(self: *@This()) Token {
        while (self.peekChar()) |c| {
            if (isIdentifierSuccessor(c)) {
                self.consume(1);
                continue;
            }

            break;
        }

        return self.createFromMarker(.identifier);
    }

    fn isIdentifierSuccessor(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    pub fn nextNumber(self: *@This()) Token {
        while (self.peekChar()) |c| {
            if (std.ascii.isDigit(c)) {
                self.consume(1);
                continue;
            }

            break;
        }

        return self.createFromMarker(.number);
    }

    pub fn nextString(self: *@This(), string_marker: u8) Token {
        const start = self.mkLoc();
        self.consume(1);
        while (self.peekChar()) |c| {
            if (c != string_marker) {
                self.consume(1);
                continue;
            }

            break;
        }
        self.consume(1);

        const end = self.mkLoc();
        return self.mkToken(.string, start, end);
    }

    pub fn nextComment(self: *@This()) Token {
        self.consume(1);
        while (self.peekChar()) |c| {
            if (c != '"') {
                self.consume(1);
                continue;
            }

            break;
        }
        self.consume(1);

        return self.createFromMarker(.comment);
    }

    pub fn consume(self: *@This(), n: usize) void {
        self.index += n;
    }

    pub fn consumeUntil(self: *@This(), u: u8) void {
        while (self.peekChar()) |c| {
            if (c == u) {
                return;
            }

            self.consume(1);
        }
    }

    pub fn peekChar(self: @This()) ?u8 {
        if (self.index >= self.source.len) return null;
        return self.source[self.index];
    }

    pub const Location = struct {
        line: usize,
        column: usize,
        index: usize,

        pub fn init(index: usize, line: usize, column: usize) @This() {
            return .{ .index = index, .line = line, .column = column };
        }

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("{},{}", .{ self.line, self.column });
        }
    };

    // TODO: add some metadata here to figure out if the token was generated from a macro yadayada
    pub const Token = struct {
        tag: Tag,
        source: []const u8,
        start: Location,
        end: Location,
        metadata: Metadata = .empty,

        pub fn init(
            source: []const u8,
            tag: Tag,
            start: Location,
            end: Location,
        ) @This() {
            return .{
                .source = source,
                .tag = tag,
                .start = start,
                .end = end,
            };
        }

        pub fn lexeme(self: @This()) []const u8 {
            return self.source[self.start.index..self.end.index];
        }

        pub fn srcLine(self: @This()) usize {
            return if (self.metadata.macro_call) |macro_call|
                macro_call.call_loc.line
            else
                self.start.line;
        }

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("{t}", .{self.tag});
            switch (self.tag) {
                .identifier, .string, .number => {
                    try writer.print("({s})", .{self.lexeme()});
                },
                else => {},
            }
            if (self.metadata.macro_call) |macro_call| {
                try writer.print(" from macro call to {s} at L{}", .{ macro_call.macro, macro_call.call_loc.line });
            }
        }

        pub const Tag = enum {
            identifier,
            string,
            number,
            comment,
            open_bracket,
            close_bracket,
            open_brace,
            close_brace,
            open_paren,
            close_paren,
            colon,
            double_colon,
            comma,
            dollar,
            dot,
            plus,
            double_plus,
            minus,
            star,
            dot_star,
            equal,
            minus_equal,
            plus_equal,
            ampersand,
            div,
            hash,
            hash_open_brace,
            hash_close_brace,

            // keywords
            push_frame,
            pop_frame,
            push_handler,
            pop_handler,
            ret_ip,
            ret_reg,
            ret,
            resume_,
            call_extern,
            call_continuation,
            jmp,
            jeq,
            jneq,
            jz,
            jnz,
            void,
            u8,
            u32,
            i32,
            perform,
            function,
            continuation,
            print,
            operation,
            @"#def",
            payload,
            fp,
            whereis,
            free,
            r0,
        };

        pub const keywords: []const Tag = &.{
            .push_frame,
            .pop_frame,
            .push_handler,
            .pop_handler,
            .ret_ip,
            .ret_reg,
            .ret,
            .resume_,
            .call_extern,
            .call_continuation,
            .jmp,
            .jeq,
            .jneq,
            .jz,
            .jnz,
            .void,
            .u8,
            .u32,
            .i32,
            .perform,
            .function,
            .continuation,
            .print,
            .operation,
            .@"#def",
            .payload,
            .fp,
            .whereis,
            .free,
            .r0,
        };

        pub const Metadata = struct {
            macro_call: ?MacroCall = null,

            pub const empty = @This(){};

            pub fn macroCall(macro: []const u8, call_token: Token) @This() {
                return .{ .macro_call = .{ .macro = macro, .call_loc = call_token.start } };
            }

            pub const MacroCall = struct {
                macro: []const u8,
                call_loc: Location,
            };
        };
    };

    pub const Error = error{
        UnknownToken,
    } || std.Io.Writer.Error;
};
