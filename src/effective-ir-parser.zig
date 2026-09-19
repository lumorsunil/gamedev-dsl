const std = @import("std");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Token = Tokenizer.Token;
const IRInstruction = @import("effect-vm.zig").IRInstruction;
const InstructionPointer = @import("effect-vm.zig").InstructionPointer;
const IRValueGeneric = @import("effect-vm.zig").IRValueGeneric;
const A = @import("allocator.zig");

pub const Parser = struct {
    source: []const u8,
    ip: usize = 0,
    tokenizer: Tokenizer,
    labels: std.StringHashMap(usize),
    token_buffer: std.ArrayList(Token) = .empty,
    instr_buffer: std.ArrayList(IRInstruction) = .empty,
    peek_buffer: std.ArrayList(Token) = .empty,
    last_token: ?Token = null,
    instr_start_marker: ?Token = null,
    macros: std.StringHashMap(Macro),
    is_applying_macros: bool = false,
    source_map: std.ArrayList(usize) = .empty,

    pub fn init(source: []const u8) @This() {
        return .{
            .source = source,
            .tokenizer = .init(source),
            .labels = .init(A.allocator),
            .macros = .init(A.allocator),
        };
    }

    fn __nextTokenInternal(self: *@This()) Error!?Token {
        const tok = (if (self.token_buffer.items.len > 0)
            self.token_buffer.orderedRemove(0)
        else
            self.tokenizer.next()) orelse return null;

        if (!self.is_applying_macros) return try self.applyMacros(tok);

        return tok;
    }

    fn applyMacros(self: *@This(), initial: Token) Error!?Token {
        self.is_applying_macros = true;
        defer self.is_applying_macros = false;

        if (initial.tag != .identifier) return initial;

        const next = try self.peekToken() orelse return initial;

        if (next.tag != .open_paren) return initial;

        _ = try self.expect(.open_paren);
        var args: std.ArrayList([]const Token) = .empty;
        var processing = true;
        while (processing) {
            var arg: std.ArrayList(Token) = .empty;

            while (try self.nextToken()) |tok_| {
                if (tok_.tag == .close_paren) {
                    processing = false;
                    break;
                }
                if (tok_.tag == .comma) {
                    break;
                }
                try arg.append(A.allocator, tok_);
            }

            try args.append(A.allocator, try arg.toOwnedSlice(A.allocator));
        }

        _ = try self.expect(.close_paren);

        return try self.nextToken();
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
            const tok = self.tokenizer.next() orelse return self.peek_buffer.items;
            try self.peek_buffer.append(A.allocator, tok);
        }

        return self.peek_buffer.items;
    }

    fn emit(self: *@This(), instruction: IRInstruction) Error!void {
        try self.instr_buffer.append(A.allocator, instruction);
        try self.source_map.append(A.allocator, self.instr_start_marker.?.start.line);
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
            .@"#def" => {
                try self.parseMacroDef();
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

    pub fn parseMacroDef(self: *@This()) Error!void {
        _ = try self.expect(.@"#def");
        const identifier = try self.expectIdentifier();

        if (self.macros.contains(identifier)) {
            std.log.err("duplicate definition of macro \"{s}\"", .{identifier});
            return Error.MacroAlreadyDefined;
        }

        var args = std.ArrayList([]const u8).empty;
        while (try self.nextToken()) |tok| {
            if (tok.tag != .identifier) break;
            try args.append(A.allocator, tok.lexeme());
        }
        _ = try self.expect(.open_brace);
        var tokens_tokens = std.ArrayList([]const Token).empty;
        var tokens = std.ArrayList(Token).empty;
        var processing = true;
        while (processing) {
            while (try self.nextToken()) |tok| {
                if (tok.tag == .hash_close_brace) {
                    processing = false;
                    break;
                }

                if (tok.tag == .hash_open_brace) {
                    const arg_identifier = try self.expectIdentifier();
                    for (args.items) |arg| {
                        if (std.mem.eql(u8, arg_identifier, arg)) break;
                    } else {
                        std.log.err("undefined macro arg \"{s}\"", .{arg_identifier});
                        return Error.UndefinedMacroArg;
                    }
                    _ = try self.expect(.close_brace);
                    break;
                }

                try tokens.append(A.allocator, tok);
            }

            try tokens_tokens.append(A.allocator, try tokens.toOwnedSlice(A.allocator));
        }

        try self.macros.put(identifier, .{ .tokens = try tokens_tokens.toOwnedSlice(A.allocator) });
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
            .ret_ip, .dollar => self.parseAssignment(initial),
            .call_extern => self.parseCallExtern(),
            .call_continuation => self.parseCallContinuation(),
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

                if (stack_variable.rel_fp) |rel_fp| {
                    if (rel_fp != 0) {
                        return Error.StackRelFpNotZero;
                    }

                    try self.emit(.init(.bind(
                        stack_variable.identifier,
                        .void_,
                    )));
                }

                const target: IRInstruction.Set.Arg.Value.Target = if (stack_variable.is_deref)
                    .deref(.identifier(stack_variable.identifier))
                else
                    .identifier(stack_variable.identifier);

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
                        .identifier_ => |s| .identifier(s),
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
            .ret_reg => {
                _ = try self.expect(.ret_reg);
                return .ret_reg;
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
                if (stack_variable.rel_fp != null) {
                    return Error.RelativeFpForValuesNotSupported;
                }
                if (stack_variable.is_deref) {
                    const inner = try A.allocator.create(IRValueGeneric);
                    inner.* = .identifier(stack_variable.identifier);
                    return .deref(inner);
                }
                return .identifier(stack_variable.identifier);
            },
            .ampersand => {
                _ = try self.expect(.ampersand);
                const stack_variable = try self.parseStackVariable();
                return .pointer(.stack(stack_variable.fp(), stack_variable.identifier));
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

    pub fn peekValueType(self: *@This()) Error!IRInstruction.Print.Format {
        const tok = try self.peekToken() orelse return self.expected("value");

        return switch (tok.tag) {
            .string => .string,
            .number => .number,
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
        rel_fp: ?isize = null,
        identifier: []const u8 = "",
        is_deref: bool = false,

        pub fn fp(self: @This()) IRValueGeneric.Pointer.Addr.Stack.Fp {
            if (self.rel_fp) |rel_fp| {
                return .rel(rel_fp);
            }
            unreachable;
        }
    };

    fn parseStackVariable(self: *@This()) Error!StackVariable {
        _ = try self.expect(.dollar);

        var stack_variable = StackVariable{};

        const rel_fp = try self.expectOptionalNumber(isize);

        if (rel_fp) |n| {
            stack_variable.rel_fp = n;
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
        if (tok.tag != expected_tag) return self.expected(@tagName(expected_tag));
        return tok;
    }

    fn expected(_: @This(), expected_tok: []const u8) Error {
        std.log.err("expected {s}", .{expected_tok});
        return Error.UnexpectedToken;
    }

    pub const Macro = struct {
        tokens: []const []const Token,

        pub fn instantiate(self: @This(), args: []const []const Token) Iterator {
            return .{ .macro = self, .args = args };
        }

        pub const Iterator = struct {
            macro: Macro,
            args: []const []const Token,
            mode: union(enum) {
                done,
                macro: struct {
                    list_index: usize = 0,
                    element_index: usize = 0,
                },
                arg: struct {
                    arg_index: usize = 0,
                    element_index: usize = 0,
                },
            },

            pub fn next(self: *@This()) ?Token {
                return switch (self.mode) {
                    .done => null,
                    .macro => |*s| {
                        const tokens = self.macro.tokens[s.list_index];
                        const tok = tokens[s.element_index];
                        s.element_index += 1;
                        if (s.element_index >= tokens.len) {
                            if (s.list_index >= self.args.len) {
                                self.mode = .done;
                            } else {
                                self.mode = .{ .arg = .{ .arg_index = s.list_index } };
                            }
                        }
                        return tok;
                    },
                    .arg => |*s| {
                        const tokens = self.args[s.arg_index];
                        const tok = tokens[s.element_index];
                        s.element_index += 1;
                        if (s.element_index >= tokens.len) {
                            if (s.arg_index + 1 >= self.macro.tokens.len) {
                                self.mode = .done;
                            } else {
                                self.mode = .{ .macro = .{ .list_index = s.arg_index + 1 } };
                            }
                        }
                        return tok;
                    },
                };
            }
        };
    };

    pub const Error = error{
        UnexpectedToken,
        DuplicateLabelDefinition,
        NotYetImplemented,
        NotSupported,
        StackRelFpNotZero,
        RelativeFpForValuesNotSupported,
        MacroAlreadyDefined,
        UndefinedMacroArg,
    } || std.mem.Allocator.Error || std.fmt.ParseIntError;
};
