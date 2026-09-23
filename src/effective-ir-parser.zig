const std = @import("std");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Token = Tokenizer.Token;
const IRInstruction = @import("effect-vm.zig").IRInstruction;
const InstructionPointer = @import("effect-vm.zig").InstructionPointer;
const IRValueGeneric = @import("effect-vm.zig").IRValueGeneric;
const A = @import("allocator.zig");

const Preprocessor = struct {
    token_buffer: std.ArrayList(Token) = .empty,
    macros: std.StringHashMap(Macro),
    is_applying_macros: bool = false,

    pub fn init() @This() {
        return .{
            .macros = .init(A.allocator),
        };
    }

    fn log(_: @This(), comptime fmt: []const u8, args: anytype) void {
        std.log.debug(fmt, args);
    }

    fn tokenizer(self: *@This()) *Tokenizer {
        const parser: *Parser = @fieldParentPtr("preprocessor", self);
        return &parser.tokenizer;
    }

    fn nextToken(self: *@This()) Parser.Error!?Token {
        const tok = (if (self.token_buffer.items.len > 0)
            self.token_buffer.orderedRemove(0)
        else
            try self.tokenizer().next()) orelse return null;

        if (tok.tag == .@"#def") {
            try self.parseMacroDef();
            return self.nextToken();
        }

        if (!self.is_applying_macros) return try self.applyMacros(tok);

        return tok;
    }

    fn applyMacros(self: *@This(), initial: Token) Parser.Error!?Token {
        self.is_applying_macros = true;
        defer self.is_applying_macros = false;

        if (initial.tag != .identifier) return initial;

        const next = try self.nextToken() orelse return initial;

        if (next.tag != .open_paren) {
            try self.token_buffer.insert(A.allocator, 0, next);
            return initial;
        }

        self.log("applying macros", .{});

        const macro = self.macros.get(initial.lexeme()) orelse {
            std.log.err("macro {s} not defined", .{initial.lexeme()});
            return Parser.Error.MacroNotDefined;
        };

        var args: std.ArrayList(Token) = .empty;
        var mode: enum { param, delim } = .param;
        while (try self.nextToken()) |tok| {
            if (tok.tag == .close_paren) {
                break;
            }
            switch (mode) {
                .delim => {
                    mode = .param;
                    if (tok.tag != .comma) return self.expected(", or )");
                },
                .param => {
                    mode = .delim;
                    try args.append(A.allocator, tok);
                },
            }
        } else return self.expected(", or )");

        if (macro.params.len != args.items.len) {
            std.log.err("macro {s} expected {} arguments, found {}", .{ macro.identifier, macro.params.len, args.items.len });
            return Parser.Error.MacroNumberOfArguments;
        }

        var it = macro.instantiate(args.items);
        var macro_tokens: std.ArrayList(Token) = .empty;
        while (try it.next()) |it_tok| {
            var it_tok_with_metadata = it_tok;
            it_tok_with_metadata.metadata = .macroCall(macro.identifier, initial);
            try macro_tokens.append(A.allocator, it_tok_with_metadata);
        }
        try self.token_buffer.insertSlice(A.allocator, 0, macro_tokens.items);

        return try self.nextToken();
    }

    fn parseMacroParams(self: *@This()) Parser.Error![]const []const u8 {
        var params = std.ArrayList([]const u8).empty;
        while (try self.nextToken()) |tok| {
            // self.log("start: token_buffer:{} peek_buffer:{} tokenizer.index:{}", .{ self.token_buffer.items.len, self.peek_buffer.items.len, self.tokenizer.index });
            if (tok.tag != .identifier) {
                if (tok.tag != .open_brace) return self.expected("{ or macro parameter");
                break;
            }
            try params.append(A.allocator, tok.lexeme());
            // self.log("adding arg {f}", .{tok});
            // self.log("end: token_buffer:{} peek_buffer:{} tokenizer.index:{}", .{ self.token_buffer.items.len, self.peek_buffer.items.len, self.tokenizer.index });
        }
        return try params.toOwnedSlice(A.allocator);
    }

    fn parseMacroBody(self: *@This(), params: []const []const u8) Parser.Error!Macro.Body {
        var tokens_tokens = std.ArrayList([]const Token).empty;
        var body_args = std.ArrayList(Macro.Body.BodyArg).empty;
        var processing = true;
        while (processing) {
            // self.log("processing tokens", .{});
            var tokens = std.ArrayList(Token).empty;
            while (try self.nextToken()) |tok| {
                // self.log("processing token {f}", .{tok});

                if (tok.tag == .hash_close_brace) {
                    // self.log("encountered #}}", .{});
                    processing = false;
                    break;
                }

                if (tok.tag == .hash_open_brace) {
                    // self.log("encountered #{{", .{});
                    try body_args.append(
                        A.allocator,
                        try self.parseMacroBodyArg(tok, params),
                    );
                    break;
                }

                try tokens.append(A.allocator, tok);
            } else {
                return self.expected("macro definition");
            }

            // self.log("adding {} tokens", .{tokens.items.len});
            try tokens_tokens.append(A.allocator, tokens.items);
        }

        return .{
            .tokens = try tokens_tokens.toOwnedSlice(A.allocator),
            .body_args = try body_args.toOwnedSlice(A.allocator),
        };
    }

    fn parseMacroBodyArg(self: *@This(), initial: Token, params: []const []const u8) Parser.Error!Macro.Body.BodyArg {
        var values = std.ArrayList(Macro.Body.BodyArg.Value).empty;

        while (try self.nextToken()) |tok| {
            switch (tok.tag) {
                .identifier => {
                    const arg_identifier = tok.lexeme();
                    // self.log("arg identifier {s}", .{arg_identifier});
                    for (params, 0..) |param, i| {
                        if (std.mem.eql(u8, arg_identifier, param)) {
                            // self.log("adding body_arg {s}", .{param});
                            try values.append(A.allocator, .{ .arg = i });
                            break;
                        }
                    } else {
                        std.log.err("undefined macro arg \"{s}\"", .{arg_identifier});
                        return Parser.Error.UndefinedMacroArg;
                    }
                },
                .string => {
                    const string = tok.lexeme()[1 .. tok.lexeme().len - 1];
                    try values.append(A.allocator, .{ .string = string });
                },
                else => return self.expected("identifier or string"),
            }

            const delimiter = try self.nextToken() orelse return self.expected("++ or }");
            if (delimiter.tag == .close_brace) break;
            if (delimiter.tag == .double_plus) continue;

            return self.expected("++ or }");
        } else return self.expected("macro arg or string");

        return .{ .values = values.items, .start_token = initial };
    }

    pub fn parseMacroDef(self: *@This()) Parser.Error!void {
        // self.log("parsing macro", .{});

        // _ = try self.expect(.@"#def");
        const identifier_tok = try self.expect(.identifier);
        const identifier = identifier_tok.lexeme();

        if (self.macros.contains(identifier)) {
            std.log.err("duplicate definition of macro \"{s}\"", .{identifier});
            return Parser.Error.MacroAlreadyDefined;
        }

        const params = try self.parseMacroParams();
        const body = try self.parseMacroBody(params);

        try self.macros.put(identifier, .{ .body = body, .identifier = identifier, .params = params });
        // self.log("added macro: {f}", .{self.macros.get(identifier).?});
    }

    fn expected(_: @This(), expected_tok: []const u8) Parser.Error {
        std.log.err("expected {s}", .{expected_tok});
        return Parser.Error.UnexpectedToken;
    }

    fn expectedFound(_: @This(), expected_tok: []const u8, found: Token) Parser.Error {
        std.log.err("expected {s}, found {f}", .{ expected_tok, found });
        return Parser.Error.UnexpectedToken;
    }

    fn expect(self: *@This(), expected_tag: Token.Tag) Parser.Error!Token {
        const tok = try self.nextToken() orelse return self.expected(@tagName(expected_tag));
        if (tok.tag != expected_tag) return self.expectedFound(@tagName(expected_tag), tok);
        return tok;
    }

    pub const Macro = struct {
        identifier: []const u8,
        params: []const []const u8,
        body: Body,

        pub fn instantiate(self: @This(), args: []const Token) Iterator {
            return .{ .macro = self, .args = args };
        }

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("macro {s} (", .{self.identifier});
            for (self.params, 0..) |param, i| {
                try writer.print("{s}", .{param});
                if (i < self.params.len - 1) {
                    try writer.writeAll(", ");
                }
            }
            try writer.print(")\n{f}", .{self.body});
        }

        pub const Body = struct {
            tokens: []const []const Token,
            body_args: []const BodyArg,

            pub fn format(
                self: @This(),
                writer: *std.Io.Writer,
            ) std.Io.Writer.Error!void {
                try writer.print("tokens: ", .{});
                for (self.tokens) |ts| for (ts) |t| try writer.print("{f} ", .{t});
                try writer.print("body_args:\n", .{});
                for (self.body_args) |body_arg| try writer.print("{f}\n", .{body_arg});
            }

            pub const BodyArg = struct {
                start_token: Token,
                values: []const Value,

                pub fn format(
                    self: @This(),
                    writer: *std.Io.Writer,
                ) std.Io.Writer.Error!void {
                    try writer.writeAll("(");
                    for (self.values, 0..) |value, i| {
                        try writer.print("{f}", .{value});
                        if (i < self.values.len - 1) {
                            try writer.writeAll(" ++ ");
                        }
                    }
                    try writer.writeAll(")");
                }

                pub const Value = union(enum) {
                    arg: usize,
                    string: []const u8,

                    pub fn format(
                        self: @This(),
                        writer: *std.Io.Writer,
                    ) std.Io.Writer.Error!void {
                        try switch (self) {
                            .string => |s| writer.writeAll(s),
                            .arg => |s| writer.print("{}", .{s}),
                        };
                    }
                };
            };
        };

        pub const Iterator = struct {
            macro: Macro,
            args: []const Token,
            mode: union(enum) {
                done,
                macro: struct {
                    list_index: usize = 0,
                    element_index: usize = 0,
                },
                arg: struct {
                    tok: Token,
                    next_list_index: usize,
                },
            } = .{ .macro = .{} },

            pub fn next(self: *@This()) !?Token {
                const body = self.macro.body;
                return switch (self.mode) {
                    .done => null,
                    .macro => |*s| {
                        const tokens = body.tokens[s.list_index];
                        const element_index = s.element_index;
                        const next_list_index = s.list_index + 1;
                        s.element_index += 1;
                        if (s.element_index >= tokens.len) {
                            if (s.list_index + 1 >= body.tokens.len) {
                                self.mode = .done;
                            } else {
                                const body_arg = self.macro.body.body_args[s.list_index];

                                if (body_arg.values.len > 1) {
                                    var source_snippet = std.ArrayList(u8).empty;

                                    for (body_arg.values) |value| {
                                        switch (value) {
                                            .string => |s_| try source_snippet.appendSlice(A.allocator, s_),
                                            .arg => |s_| {
                                                const arg = self.args[s_];
                                                if (arg.tag != .identifier) return Parser.Error.UnexpectedToken;
                                                try source_snippet.appendSlice(A.allocator, arg.lexeme());
                                            },
                                        }
                                    }

                                    const loc = body_arg.start_token.start;
                                    self.mode = .{ .arg = .{
                                        .tok = .{
                                            .source = source_snippet.items,
                                            .tag = if (source_snippet.items[0] == '"') .string else .identifier,
                                            .start = .init(0, loc.line, loc.column),
                                            .end = .init(source_snippet.items.len, loc.line, loc.column),
                                        },
                                        .next_list_index = next_list_index,
                                    } };
                                } else {
                                    const arg = self.args[body_arg.values[0].arg];
                                    self.mode = .{ .arg = .{
                                        .tok = arg,
                                        .next_list_index = next_list_index,
                                    } };
                                }
                            }
                        }
                        if (element_index >= tokens.len) {
                            return self.next();
                        } else {
                            const tok = tokens[element_index];
                            return tok;
                        }
                    },
                    .arg => |s| {
                        const tok = s.tok;

                        self.mode = .{ .macro = .{
                            .list_index = s.next_list_index,
                        } };

                        return tok;
                    },
                };
            }
        };
    };
};

pub const Parser = struct {
    source: []const u8,
    ip: usize = 0,
    tokenizer: Tokenizer,
    labels: std.StringHashMap(usize),
    preprocessor: Preprocessor,
    instr_buffer: std.ArrayList(IRInstruction) = .empty,
    peek_buffer: std.ArrayList(Token) = .empty,
    last_token: ?Token = null,
    instr_start_marker: ?Token = null,
    source_map: std.ArrayList(Token) = .empty,

    pub fn init(source: []const u8) @This() {
        return .{
            .source = source,
            .tokenizer = .init(source),
            .labels = .init(A.allocator),
            .preprocessor = .init(),
        };
    }

    fn __nextTokenInternal(self: *@This()) Error!?Token {
        return self.preprocessor.nextToken();
    }

    fn nextToken(self: *@This()) Error!?Token {
        const tok = (if (self.peek_buffer.items.len > 0)
            self.peek_buffer.orderedRemove(0)
        else
            try self.__nextTokenInternal()) orelse return null;
        self.last_token = tok;
        return tok;
    }

    fn peekToken(self: *@This()) Error!?Token {
        if (self.peek_buffer.items.len > 0) {
            return self.peek_buffer.items[0];
        }
        const tok = try self.__nextTokenInternal() orelse return null;
        try self.peek_buffer.append(A.allocator, tok);
        return tok;
    }

    fn peekTokens(self: *@This(), n: usize) Error![]const Token {
        const h = self.peek_buffer.items.len;
        const b = n -| h;

        if (b == 0) return self.peek_buffer.items[0..n];

        for (0..b) |_| {
            const tok = try self.__nextTokenInternal() orelse return self.peek_buffer.items;
            try self.peek_buffer.append(A.allocator, tok);
        }

        return self.peek_buffer.items;
    }

    fn emit(self: *@This(), instruction: IRInstruction) Error!void {
        try self.instr_buffer.append(A.allocator, instruction);
        try self.source_map.append(A.allocator, self.instr_start_marker.?);
        self.ip += 1;
    }

    pub fn parse(self: *@This()) Error!?IRInstruction {
        if (self.popInstruction()) |instr| return instr;

        const tok = try self.peekToken() orelse return null;

        switch (tok.tag) {
            .identifier => {
                try self.parseLabel();
                return self.parse();
            },
            else => try self.parseInstruction(tok),
        }

        return self.popInstruction();
    }

    pub fn popInstruction(self: *@This()) ?IRInstruction {
        if (self.instr_buffer.items.len > 0) {
            return self.instr_buffer.orderedRemove(0);
        }
        return null;
    }

    pub fn currentToken(self: @This()) ?Token {
        return self.last_token;
    }

    pub fn parseLabel(self: *@This()) Error!void {
        const identifier = try self.expectIdentifier();
        _ = try self.expect(.colon);

        if (self.labels.contains(identifier)) {
            std.log.err("label \"{s}\" already defined", .{identifier});
            return Error.DuplicateLabelDefinition;
        }

        try self.labels.put(identifier, self.ip);
    }

    fn log(_: @This(), comptime fmt: []const u8, args: anytype) void {
        std.log.debug(fmt, args);
    }

    pub fn parseInstruction(
        self: *@This(),
        initial: Token,
    ) Error!void {
        self.instr_start_marker = initial;

        try switch (initial.tag) {
            .push_frame => self.parsePushFrame(),
            .push_handler => self.parsePushHandler(),
            .pop_handler => self.parsePopHandler(),
            .perform => self.parsePerform(),
            .resume_ => self.parseResume(),
            .jmp => self.parseJmp(),
            .jeq => self.parseJeq(),
            .jz => self.parseJz(),
            .ret => self.parseRet(),
            .r0, .ret_ip, .dollar => self.parseAssignment(initial),
            .call_extern => self.parseCallExtern(),
            .call_continuation => self.parseCallContinuation(),
            .free => self.parseFree(),
            .print => self.parsePrint(),
            else => {
                std.log.err("NYI: instruction beginning with {t}", .{initial.tag});
                return Error.NotYetImplemented;
            },
        };
    }

    pub fn parsePushFrame(self: *@This()) Error!void {
        _ = try self.expect(.push_frame);
        const string = try self.expectString();
        try self.emit(.init(.pushFrame(string)));
    }

    pub fn parsePushHandler(self: *@This()) Error!void {
        _ = try self.expect(.push_handler);
        const effect_id = try self.expectNumber(usize);
        _ = try self.expect(.colon);
        const label = try self.expectIdentifier();

        try self.emit(.init(.pushHandler(effect_id, .label(label))));
    }

    pub fn parsePopHandler(self: *@This()) Error!void {
        _ = try self.expect(.pop_handler);
        const effect_id = try self.expectNumber(usize);

        try self.emit(.init(.popHandler(effect_id)));
    }

    pub fn parsePerform(self: *@This()) Error!void {
        _ = try self.expect(.perform);
        const effect_id = try self.expectNumber(usize);
        const operation = try self.expectString();

        try self.emit(.init(.perform(effect_id, operation)));
    }

    pub fn parseResume(self: *@This()) Error!void {
        _ = try self.expect(.resume_);
        const payload = try self.parseValue();

        try self.emit(.init(.resume_(payload)));
    }

    pub fn parseJmp(self: *@This()) Error!void {
        _ = try self.expect(.jmp);
        const target = try self.parseIPAddr();

        try self.emit(.init(.jmp(target)));
    }

    pub fn parseJeq(self: *@This()) Error!void {
        _ = try self.expect(.jeq);
        const lhs = try self.parseValue();
        const rhs = try self.parseValue();
        const target = try self.parseIPAddr();

        try self.emit(.init(.jeq(lhs, rhs, target)));
    }

    pub fn parseJz(self: *@This()) Error!void {
        _ = try self.expect(.jz);
        const value = try self.parseValue();
        const target = try self.parseIPAddr();

        try self.emit(.init(.jz(value, target)));
    }

    pub fn parseRet(self: *@This()) Error!void {
        _ = try self.expect(.ret);
        const value = try self.parseValue();

        try self.emit(.init(.ret(value)));
    }

    pub fn parseAssignment(self: *@This(), initial: Token) Error!void {
        switch (initial.tag) {
            .r0 => {
                _ = try self.expect(.r0);
                _ = try self.expect(.equal);
                const value = try self.parseValue();

                try self.emit(.init(.set(.value(.r0, value))));
            },
            .ret_ip => {
                _ = try self.expect(.ret_ip);
                _ = try self.expect(.equal);
                const value = try self.parseIPAddr();

                try self.emit(.init(.set(.ip(.ret_ip, value))));
            },
            .dollar => {
                const stack_variable = try self.parseStackVariable();
                const op = try self.parseAssignmentOp();
                var value = try self.parseValue();

                switch (stack_variable.fp) {
                    .abs, .rel_value, .unset => {},
                    .rel => |rel_fp| {
                        if (rel_fp != 0) {
                            return Error.StackRelFpNotZero;
                        }

                        if (value == .pop_frame) {
                            try self.emit(.init(.bind(
                                stack_variable.identifier,
                                .pop_frame,
                            )));
                            return;
                        } else {
                            try self.emit(.init(.bind(
                                stack_variable.identifier,
                                .void_,
                            )));
                        }
                    },
                }

                const target: IRInstruction.Set.Arg.Value.Target = if (stack_variable.is_deref)
                    .deref(stack_variable.toValue())
                else
                    stack_variable.toTarget();

                const ath_op: ?IRValueGeneric.Ath.Op = switch (op) {
                    .equal => null,
                    .minus_equal => .sub,
                    .plus_equal => .add,
                    else => return self.expected("assignment operator"),
                };
                if (ath_op) |ath_op_| {
                    const lhs = try A.allocator.create(IRValueGeneric);
                    lhs.* = switch (target) {
                        .deref_ => |s| .deref(brk: {
                            const p = try A.allocator.create(IRValueGeneric);
                            p.* = s.pointer;
                            break :brk p;
                        }),
                        .stack_variable => |s| .{ .stack_variable = s },
                        .r0 => .r0,
                        .ret_reg => .ret_reg,
                    };
                    const value_ = try A.allocator.create(IRValueGeneric);
                    value_.* = value;

                    const type_: IRValueGeneric.Ath.Type = switch (self.currentToken().?.tag) {
                        .u8 => .u8,
                        .u32 => .u32,
                        .i32 => .i32,
                        else => unreachable,
                    };

                    value = .ath(lhs, value_, ath_op_, type_);
                }

                try self.emit(.init(.set(.value(target, value))));
            },
            else => {
                std.log.err("NYI: assignment beginning with {t}", .{initial.tag});
                return Error.NotYetImplemented;
            },
        }
    }

    pub fn parseIPAddr(self: *@This()) Error!InstructionPointer {
        const tok = try self.peekToken() orelse return self.expected("ip addr");

        switch (tok.tag) {
            .colon => {
                _ = try self.expect(.colon);
                const label = try self.expectIdentifier();
                return .label(label);
            },
            .identifier => {
                const identifier = try self.expectIdentifier();

                if (!std.mem.eql(u8, identifier, "ip")) {
                    return self.expected("ip");
                }

                const operator = try self.expectAny();
                var number = try self.expectNumber(isize);
                if (operator.tag == .minus) {
                    number = -number;
                } else if (operator.tag != .plus) {
                    return self.expected("plus or minus");
                }

                return .rel(number);
            },
            .dollar => {
                const value = try A.allocator.create(IRValueGeneric);
                value.* = try self.parseValue();

                return .value(value);
            },
            else => {
                std.log.err("ip addr beginning with token \"{t}\" not supported", .{tok.tag});
                return Error.NotSupported;
            },
        }
    }

    pub fn parseValue(self: *@This()) Error!IRValueGeneric {
        const tok = try self.peekToken() orelse return self.expected("value");

        switch (tok.tag) {
            .void => {
                _ = try self.expect(.void);
                return .void_;
            },
            .r0 => {
                _ = try self.expect(.r0);
                return .r0;
            },
            .ret_reg => {
                _ = try self.expect(.ret_reg);
                return .ret_reg;
            },
            .payload => {
                _ = try self.expect(.payload);
                return .payload;
            },
            .whereis => {
                _ = try self.expect(.whereis);
                const identifier = try self.expectIdentifier();
                return .whereis(identifier);
            },
            .fp => {
                _ = try self.expect(.fp);
                return .fp;
            },
            .function => {
                _ = try self.expect(.function);
                _ = try self.expect(.colon);
                const label = try self.expectIdentifier();
                return .function(.label(label));
            },
            .continuation => {
                _ = try self.expect(.continuation);
                const stack_frames = try self.parseValue();
                _ = try self.expect(.colon);
                const label = try self.expectIdentifier();
                return .continuation(stack_frames, .label(label));
            },
            .operation => {
                _ = try self.expect(.operation);
                return .operation;
            },
            .string => return .literal(try self.expectString()),
            .number => {
                _ = try self.nextToken();
                _ = try self.expect(.double_colon);
                const type_tok = try self.expectAny();

                switch (type_tok.tag) {
                    .i32 => {
                        const n = try std.fmt.parseInt(i32, tok.lexeme(), 10);
                        return .literal(try A.allocator.dupe(u8, std.mem.asBytes(&n)));
                    },
                    .u8 => {
                        const n = try std.fmt.parseInt(u8, tok.lexeme(), 10);
                        return .literal(try A.allocator.dupe(u8, std.mem.asBytes(&n)));
                    },
                    .u32 => {
                        const n = try std.fmt.parseInt(u32, tok.lexeme(), 10);
                        return .literal(try A.allocator.dupe(u8, std.mem.asBytes(&n)));
                    },
                    else => {
                        return self.expected("number type (i32, u8 or u32)");
                    },
                }
            },
            .dollar => {
                const stack_variable = try self.parseStackVariable();
                const value = stack_variable.toValue();

                if (stack_variable.is_deref) {
                    const inner = try A.allocator.create(IRValueGeneric);
                    inner.* = value;
                    return .deref(inner);
                }

                return value;
            },
            .ampersand => {
                _ = try self.expect(.ampersand);
                const stack_variable = try self.parseStackVariable();
                return stack_variable.toPointer();
            },
            .pop_frame => {
                _ = try self.expect(.pop_frame);
                return .pop_frame;
            },
            .open_brace => {
                _ = try self.expect(.open_brace);
                var bytes = std.ArrayList(u8).empty;
                while (try self.expectOptionalNumber(u8)) |n| {
                    try bytes.append(A.allocator, n);
                }
                _ = try self.expect(.close_brace);
                return .literal(try bytes.toOwnedSlice(A.allocator));
            },
            else => {
                std.log.err("value beginning with token \"{t}\" not supported", .{tok.tag});
                return Error.NotSupported;
            },
        }
    }

    // TODO: handle annotated numbers?
    pub fn peekValueType(self: *@This()) Error!IRInstruction.Print.Format {
        const tok = try self.peekToken() orelse return self.expected("value");

        return switch (tok.tag) {
            .string => .string,
            .number => .number,
            .fp => .number,
            else => .any,
        };
    }

    fn parseAssignmentOp(self: *@This()) Error!Token.Tag {
        const tok = try self.expectAny();

        return switch (tok.tag) {
            .equal, .minus_equal, .plus_equal => tok.tag,
            else => self.expected("assignment op"),
        };
    }

    const StackVariable = struct {
        fp: IRValueGeneric.StackVariable.Fp = .unset,
        identifier: []const u8 = "",
        is_deref: bool = false,

        pub fn toValue(self: @This()) IRValueGeneric {
            return .stackVariable(self.fp, self.identifier);
        }

        pub fn toPointer(self: @This()) IRValueGeneric {
            return .pointer(.stack(self.fp, self.identifier));
        }

        pub fn toTarget(self: @This()) IRInstruction.Set.Arg.Value.Target {
            return .stackVariable(self.fp, self.identifier);
        }
    };

    fn parseStackVariable(self: *@This()) Error!StackVariable {
        _ = try self.expect(.dollar);

        var stack_variable = StackVariable{};

        const rel_fp = try self.expectOptionalNumber(isize);

        if (rel_fp) |n| {
            stack_variable.fp = .{ .rel = n };
        }

        if (try self.expectOptional(.open_bracket)) |_| {
            const value = try A.allocator.create(IRValueGeneric);
            value.* = try self.parseValue();

            stack_variable.fp = .{ .rel_value = value };
            _ = try self.expect(.close_bracket);
        }

        _ = try self.expect(.dot);

        stack_variable.identifier = try self.expectIdentifier();

        if (try self.peekToken()) |deref| {
            if (deref.tag == .dot_star) {
                _ = try self.nextToken();
                stack_variable.is_deref = true;
            }
        }

        return stack_variable;
    }

    pub fn parseCallExtern(self: *@This()) Error!void {
        _ = try self.expect(.call_extern);
        const identifier = try self.expectString();
        _ = try self.expect(.open_bracket);
        var args: std.ArrayList(IRValueGeneric) = .empty;

        while (true) {
            const tok = try self.peekToken() orelse return self.expected("value or ]");
            switch (tok.tag) {
                .close_bracket => {
                    _ = try self.nextToken();
                    break;
                },
                else => {
                    const value = try self.parseValue();
                    try args.append(A.allocator, value);
                },
            }
        }

        try self.emit(.init(.callExternFn(
            identifier,
            try args.toOwnedSlice(A.allocator),
        )));
    }

    pub fn parseCallContinuation(self: *@This()) Error!void {
        _ = try self.expect(.call_continuation);

        const continuation = try self.parseValue();
        const payload = try self.parseValue();

        try self.emit(.init(.callCont(
            continuation,
            payload,
        )));
    }

    pub fn parseFree(self: *@This()) Error!void {
        _ = try self.expect(.free);
        const value = try self.parseValue();
        try self.emit(.init(.free(value)));
    }

    pub fn parsePrint(self: *@This()) Error!void {
        _ = try self.expect(.print);

        const format = try self.peekValueType();
        const value = try self.parseValue();

        try self.emit(.init(.print(format, value)));
    }

    fn expectAny(self: *@This()) Error!Token {
        const tok = try self.nextToken() orelse return self.expected("not eof");
        return tok;
    }

    fn expectIdentifier(self: *@This()) Error![]const u8 {
        const tok = try self.expect(.identifier);
        return tok.lexeme();
    }

    fn expectString(self: *@This()) Error![]const u8 {
        const tok = try self.expect(.string);
        return std.mem.trim(u8, tok.lexeme(), "\"");
    }

    fn expectNumber(self: *@This(), comptime T: type) Error!T {
        const tok = try self.expect(.number);
        return std.fmt.parseInt(T, tok.lexeme(), 10);
    }

    fn expectOptional(self: *@This(), tag: Token.Tag) Error!?Token {
        const tok = try self.peekToken() orelse return null;
        if (tok.tag == tag) {
            return try self.nextToken();
        }
        return null;
    }

    fn expectOptionalNumber(self: *@This(), comptime T: type) Error!?T {
        const tok = try self.expectOptional(.number) orelse return null;
        return try std.fmt.parseInt(T, tok.lexeme(), 10);
    }

    fn expect(self: *@This(), expected_tag: Token.Tag) Error!Token {
        const tok = try self.nextToken() orelse return self.expected(@tagName(expected_tag));
        if (tok.tag != expected_tag) return self.expectedFound(@tagName(expected_tag), tok);
        return tok;
    }

    fn expected(_: @This(), expected_tok: []const u8) Error {
        std.log.err("expected {s}", .{expected_tok});
        return Error.UnexpectedToken;
    }

    fn expectedFound(_: @This(), expected_tok: []const u8, found: Token) Error {
        std.log.err("expected {s}, found {f}", .{ expected_tok, found });
        return Error.UnexpectedToken;
    }

    pub const Error = error{
        UnexpectedToken,
        DuplicateLabelDefinition,
        NotYetImplemented,
        NotSupported,
        StackRelFpNotZero,
        AssignmentRelativeFpAsValueNotSupported,
        MacroAlreadyDefined,
        UndefinedMacroArg,
        MacroNotDefined,
        MacroNumberOfArguments,
        PointerRequiresFPSpecifier,
    } || std.mem.Allocator.Error || std.fmt.ParseIntError || Tokenizer.Error;
};
