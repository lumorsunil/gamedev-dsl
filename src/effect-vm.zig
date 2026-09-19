const std = @import("std");
const Allocator = std.mem.Allocator;
const A = @import("allocator.zig");
const rl = @import("raylib");

const Library = struct {
    pub const Source = rl;

    pub fn resolveSymbol(comptime symbol: []const u8) @TypeOf(@field(Source, symbol)) {
        return @field(Source, symbol);
    }
};

pub const IRValue = []const u8;
const EffectId = usize;
pub const InstructionPointer = union(enum) {
    abs_: usize,
    rel_: isize,
    label_: Label,
    value_: *IRValueGeneric,

    pub fn abs(ip: usize) @This() {
        return .{ .abs_ = ip };
    }

    pub fn rel(rel_ip: isize) @This() {
        return .{ .rel_ = rel_ip };
    }

    pub fn label(label_: []const u8) @This() {
        return .{ .label_ = label_ };
    }

    pub fn value(value_: *IRValueGeneric) @This() {
        return .{ .value_ = value_ };
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try switch (self) {
            .abs_ => |s| writer.print("#{}", .{s}),
            .rel_ => |s| writer.print("#+{}", .{s}),
            .label_ => |s| writer.print("#L'{s}'", .{s}),
            .value_ => |s| writer.print("#({f})", .{s}),
        };
    }

    pub const Label = []const u8;
};

pub const IRValueGeneric = union(enum) {
    literal_: IRValue,
    identifier_: []const u8,
    pointer_: Pointer,
    function_: Function,
    continuation_: *@This().Continuation,
    deref_: Deref,
    operation,
    payload,
    ath_: Ath,
    // TODO: remove when we can have multiple arguments to handler effects/functions in general
    resume_,
    ret_reg,
    pop_frame,
    void_,

    pub fn literal(v: []const u8) @This() {
        return .{ .literal_ = v };
    }

    pub fn identifier(identifier_: []const u8) @This() {
        return .{ .identifier_ = identifier_ };
    }

    pub fn pointer(pointer_: Pointer) @This() {
        return .{ .pointer_ = pointer_ };
    }

    pub fn ath(lhs: *const IRValueGeneric, rhs: *const IRValueGeneric, op: Ath.Op, type_: Ath.Type) @This() {
        return .{ .ath_ = .{ .lhs = lhs, .rhs = rhs, .op = op, .type = type_ } };
    }

    pub fn function(ip: InstructionPointer) @This() {
        return .{ .function_ = .{ .ip = ip } };
    }

    pub fn continuation(stack_frames: IRValueGeneric, ip: InstructionPointer) !@This() {
        const continuation_ = try A.allocator.create(@This().Continuation);
        continuation_.* = .{
            .stack_frames = stack_frames,
            .ip = ip,
        };
        return .{ .continuation_ = continuation_ };
    }

    pub fn deref(value: *const IRValueGeneric) @This() {
        return .{ .deref_ = .{ .value = value } };
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .literal_ => |s| try writer.print("literal({})", .{s.len}),
            .identifier_ => |s| try writer.print("@{s}", .{s}),
            inline .pointer_, .deref_, .function_, .continuation_, .ath_ => |s| try writer.print("{f}", .{s}),
            .operation => try writer.writeAll("%operation"),
            .payload => try writer.writeAll("%payload"),
            .resume_ => try writer.writeAll("%resume"),
            .ret_reg => try writer.writeAll("%ret"),
            .pop_frame => try writer.writeAll("pop_frame"),
            .void_ => try writer.writeAll("void"),
        }
    }

    pub const Function = struct {
        ip: InstructionPointer,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("fn:{f}", .{self.ip});
        }
    };

    pub const Continuation = struct {
        stack_frames: IRValueGeneric,
        ip: InstructionPointer,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("cont_fn:{f}", .{self.ip});
        }
    };

    pub const Pointer = struct {
        addr: Addr,
        mod: Mod = .none,

        pub fn stack(fp: Addr.Stack.Fp, identifier_: []const u8) @This() {
            return .{ .addr = .{ .stack = .{ .identifier = identifier_, .fp = fp } } };
        }

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("&{f}{f}", .{ self.addr, self.mod });
        }

        pub const Addr = union(enum) {
            stack: Stack,

            pub fn format(
                self: @This(),
                writer: *std.Io.Writer,
            ) std.Io.Writer.Error!void {
                switch (self) {
                    inline else => |s| try writer.print("{f}", .{s}),
                }
            }

            pub const Stack = struct {
                fp: Fp,
                identifier: []const u8,

                pub fn format(
                    self: @This(),
                    writer: *std.Io.Writer,
                ) std.Io.Writer.Error!void {
                    try writer.print("{f}.@{s}", .{ self.fp, self.identifier });
                }

                pub const Fp = union(enum) {
                    abs_: usize,
                    rel_: isize,

                    pub fn abs(fp: usize) @This() {
                        return .{ .abs_ = fp };
                    }

                    pub fn rel(rel_fp: isize) @This() {
                        return .{ .rel_ = rel_fp };
                    }

                    pub fn format(
                        self: @This(),
                        writer: *std.Io.Writer,
                    ) std.Io.Writer.Error!void {
                        try switch (self) {
                            .abs_ => |s| writer.print("$({})", .{s}),
                            .rel_ => |s| writer.print("$+({})", .{s}),
                        };
                    }
                };
            };
        };

        pub const Mod = union(enum) {
            none,
            add_: isize,

            pub fn add(delta: isize) @This() {
                return .{ .add_ = delta };
            }

            pub fn format(
                self: @This(),
                writer: *std.Io.Writer,
            ) std.Io.Writer.Error!void {
                switch (self) {
                    .none => {},
                    .add_ => |s| try writer.print("[+{}]", .{s}),
                }
            }
        };
    };

    pub const Deref = struct {
        value: *const IRValueGeneric,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("{f}.*", .{self.value.*});
        }
    };

    pub const Ath = struct {
        lhs: *const IRValueGeneric,
        rhs: *const IRValueGeneric,
        type: Type,
        op: Op,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("{f} {f} {f}", .{ self.lhs, self.op, self.rhs });
        }

        pub const Type = enum {
            u8,
            u32,
            i32,
        };

        pub const Op = enum {
            add,
            sub,

            pub fn format(
                self: @This(),
                writer: *std.Io.Writer,
            ) std.Io.Writer.Error!void {
                try switch (self) {
                    .add => writer.writeByte('+'),
                    .sub => writer.writeByte('-'),
                };
            }
        };
    };
};

pub const StackFrame = struct {
    label: []const u8,
    ret_ip: InstructionPointer,
    handlers: std.ArrayList(Handler) = .empty,
    map: std.StringHashMap(V),
    ret_reg: IRValue = &.{},

    // Handler frame fields
    effect_id: ?usize = null,
    operation: ?IRValue = null,
    payload: ?IRValue = null,
    // TODO: remove when we can have multiple arguments to handler effects/functions in general
    resume_: ?*Continuation = null,

    pub const K = []const u8;
    pub const V = IRValue;

    pub fn init(label: []const u8, ip: InstructionPointer) @This() {
        return .{ .label = label, .ret_ip = ip, .map = .init(A.allocator) };
    }

    pub fn deinit(self: *@This()) void {
        var it = self.map.valueIterator();
        while (it.next()) |value| A.allocator.free(value.*);
        self.map.clearAndFree();
        self.handlers.deinit(A.allocator);
        if (self.payload) |payload| {
            A.allocator.free(payload);
            self.payload = null;
        }
        if (self.resume_) |continuation| continuation.deinit();
    }

    pub fn clone(self: @This()) !@This() {
        var copy = self;

        copy.map = try copy.map.clone();
        var it = copy.map.valueIterator();
        while (it.next()) |value| {
            value.* = try A.allocator.dupe(u8, value.*);
        }
        copy.handlers = try copy.handlers.clone(A.allocator);
        copy.payload = if (copy.payload) |payload| try A.allocator.dupe(u8, payload) else null;
        copy.ret_reg = try A.allocator.dupe(u8, copy.ret_reg);

        return copy;
    }

    pub fn pushHandler(self: *@This(), handler: Handler) !void {
        try self.handlers.append(A.allocator, handler);
    }

    /// Returns true if a handler was removed, false if there were no handlers to pop.
    pub fn popHandler(self: *@This(), effect_id: EffectId) bool {
        var handler_index = self.handlers.items.len;
        while (handler_index > 0) {
            handler_index -= 1;
            const handler = self.handlers.items[handler_index];
            if (handler.effect_id == effect_id) {
                _ = self.handlers.orderedRemove(handler_index);
                return true;
            }
        }

        return false;
    }

    pub fn put(self: *@This(), key: K, value: anytype) !void {
        const bytes = std.mem.asBytes(&value);
        const value_ptr = try A.allocator.dupe(u8, bytes);
        self.map.put(key, value_ptr);
    }

    pub fn get(self: *@This(), comptime T: type, key: K) ?T {
        const ptr = self.getPtr(T, key) orelse return null;
        return ptr.*;
    }

    pub fn getPtr(self: *@This(), comptime T: type, key: K) ?*T {
        const bytes = self.map.get(key) orelse return null;
        return std.mem.bytesAsValue(T, bytes.ptr);
        // return @as(*T, @ptrCast(@alignCast(ptr)));
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{s}_frame [ret_ip:{f}]\n", .{ self.label, self.ret_ip });

        for (self.handlers.items) |handler| {
            try writer.print("{f}\n", .{handler});
        }

        var it = self.map.iterator();
        while (it.next()) |entry| {
            try writer.print("  \"{s}\": {any}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }
};

pub const Handler = struct {
    effect_id: EffectId,
    handler_ip: usize,
    saved_vm_fp: usize,
    original_fp: usize,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print(
            "handler effect_id:{} handler_ip:{} saved_vm_fp:{} original_fp:{}",
            .{ self.effect_id, self.handler_ip, self.saved_vm_fp, self.original_fp },
        );
    }
};

pub const Continuation = struct {
    saved_frames: []const StackFrame,
    saved_ip: usize,

    pub fn init(frames: []const StackFrame, saved_ip: usize) @This() {
        return .{ .saved_frames = frames, .saved_ip = saved_ip };
    }

    // TODO: where to call this?
    pub fn deinit(self: *@This()) void {
        for (self.saved_frames) |*frame| frame.deinit();
        A.allocator.free(self.saved_frames);
    }
};

pub const VM = struct {
    frames: std.ArrayList(StackFrame) = .empty,
    instructions: []const IRInstruction,
    ip: usize = 0,
    labels: std.StringHashMap(usize),
    source_map: []const usize,

    pub fn init(
        instructions: []const IRInstruction,
        labels: std.StringHashMap(usize),
        source_map: []const usize,
    ) !@This() {
        return .{
            .instructions = instructions,
            .labels = try labels.clone(),
            .source_map = source_map,
        };
    }

    pub fn deinit(self: *@This()) void {
        for (self.frames.items) |*frame| frame.deinit();
        self.frames.deinit(A.allocator);
    }

    pub fn run(self: *@This()) !IRValue {
        while (self.ip < self.instructions.len) {
            switch (try self.step()) {
                .cont => {
                    self.ip += 1;
                    continue;
                },
                .cont_no_ip_inc => continue,
                .ret => |s| return s,
            }
        }
        return self.getCurrentFrame().ret_reg;
    }

    pub const StepEvent = union(enum) {
        cont,
        cont_no_ip_inc,
        ret: IRValue,
    };

    pub fn step(self: *@This()) !StepEvent {
        const instruction = self.instructions[self.ip];

        // self.log("", .{});
        // self.logStackFrame();
        // self.log("", .{});
        // self.logCurrentInstruction();

        return switch (instruction.instruction_type) {
            .jmp_ => |s| self.handleJump(s),
            .jeq_ => |s| self.handleJumpIfEqual(s),
            .jneq_ => |s| self.handleJumpIfNotEqual(s),
            .jz_ => |s| self.handleJumpIfEqualZero(s),
            .jnz_ => |s| self.handleJumpIfNotEqualZero(s),
            .call_extern_fn => |s| self.handleCallExternFunction(s),
            .call_cont => |s| self.handleCallContinuation(s),
            .unwind_ => |s| self.handleUnwind(s),
            .push_frame_ => |s| self.handlePushFrame(s),
            .push_handler => |s| self.handlePushHandler(s),
            .pop_handler => |s| self.handlePopHandler(s),
            .perform_ => |s| self.handlePerform(s),
            .resume__ => |s| self.handleResume(s),
            .bind_ => |s| self.handleBind(s),
            .inc_ => |s| self.handleInc(s),
            .dec_ => |s| self.handleDec(s),
            .set_ => |s| self.handleSet(s),
            .print_ => |s| self.handlePrint(s),
        };
    }

    pub fn dupeFrames(self: @This(), start_index: usize) ![]StackFrame {
        if (self.frames.items.len == 0) return &.{};
        std.debug.assert(start_index < self.frames.items.len);
        const n_frames = self.frames.items.len - start_index;
        const snapshot_frames = try A.allocator.alloc(StackFrame, n_frames);
        for (self.frames.items[start_index..], 0..) |frame, i| {
            snapshot_frames[i] = try frame.clone();
        }
        return snapshot_frames;
    }

    fn findHandler(self: *@This(), effect_id: EffectId) ?*Handler {
        var frame_index = self.frames.items.len;

        while (frame_index > 0) {
            frame_index -= 1;
            const frame = &self.frames.items[frame_index];

            var handler_index = frame.handlers.items.len;
            while (handler_index > 0) {
                handler_index -= 1;
                const handler = &frame.handlers.items[handler_index];

                if (handler.effect_id == effect_id) {
                    return handler;
                }
            }
        }

        return null;
    }

    fn log(_: @This(), comptime fmt: []const u8, args: anytype) void {
        std.log.debug(fmt, args);
    }

    fn logStackFrame(self: @This()) void {
        for (self.frames.items, 0..) |frame, i| {
            self.log("SF:[{}]: {f}", .{ i, frame });
        }
    }

    fn logCurrentInstruction(self: @This()) void {
        const instruction = self.instructions[self.ip];
        self.log("[{}] {f}", .{ self.ip, instruction });
    }

    fn handleJump(self: *@This(), jmp: IRInstruction.Jump) !StepEvent {
        self.ip = try self.evaluateInstructionPointer(jmp.ip);
        return .cont_no_ip_inc;
    }

    fn handleJumpIfEqual(self: *@This(), jeq: IRInstruction.JumpIfEqual) !StepEvent {
        const lhs = try self.evaluateValueGenericEnsureExists(jeq.lhs);
        const rhs = try self.evaluateValueGenericEnsureExists(jeq.rhs);

        if (std.mem.eql(u8, lhs, rhs)) {
            self.ip = try self.evaluateInstructionPointer(jeq.ip);
            return .cont_no_ip_inc;
        }

        return .cont;
    }

    fn handleJumpIfNotEqual(self: *@This(), jneq: IRInstruction.JumpIfNotEqual) !StepEvent {
        const lhs = try self.evaluateValueGenericEnsureExists(jneq.lhs);
        const rhs = try self.evaluateValueGenericEnsureExists(jneq.rhs);

        if (!std.mem.eql(u8, lhs, rhs)) {
            self.ip = try self.evaluateInstructionPointer(jneq.ip);
            return .cont_no_ip_inc;
        }

        return .cont;
    }

    fn handleJumpIfEqualZero(
        self: *@This(),
        jz: IRInstruction.JumpIfEqualZero,
    ) !StepEvent {
        const value = try self.evaluateValueGenericEnsureExists(jz.value);

        for (value) |b| if (b == 0) {
            self.ip = try self.evaluateInstructionPointer(jz.ip);
            return .cont_no_ip_inc;
        };

        return .cont;
    }

    fn handleJumpIfNotEqualZero(
        self: *@This(),
        jnz: IRInstruction.JumpIfNotEqualZero,
    ) !StepEvent {
        const value = try self.evaluateValueGenericEnsureExists(jnz.value);

        for (value) |b| if (b != 0) {
            self.ip = try self.evaluateInstructionPointer(jnz.ip);
            return .cont_no_ip_inc;
        };

        return .cont;
    }

    fn handleCallExternFunction(self: *@This(), call_extern_fn: IRInstruction.CallExternFunction) !StepEvent {
        @setEvalBranchQuota(10000);
        next_symbol: inline for (comptime std.meta.declarations(Library.Source)) |decl| {
            const f = comptime Library.resolveSymbol(decl.name);
            const info = @typeInfo(@TypeOf(f));

            if (comptime info == .@"fn") {
                comptime {
                    const function_info = info.@"fn";
                    var argument_field_list: [function_info.params.len]type = undefined;
                    for (function_info.params, 0..) |arg, i| {
                        const T = arg.type orelse continue :next_symbol;
                        argument_field_list[i] = T;
                    }
                }

                if (std.mem.eql(u8, decl.name, call_extern_fn.symbol)) {
                    const Args = std.meta.ArgsTuple(@TypeOf(f));

                    var args: Args = undefined;

                    inline for (std.meta.fields(Args), 0..) |field, i| {
                        const ext_arg = call_extern_fn.args[i];
                        const arg = try self.evaluateValueGenericEnsureExists(ext_arg);
                        switch (@typeInfo(field.type)) {
                            .pointer => |p| {
                                if (comptime p.child == u8 and p.sentinel() == 0) {
                                    @field(args, field.name) = try std.fmt.allocPrintSentinel(A.allocator, "{s}", .{arg}, 0);
                                } else if (comptime p.child == u8) {
                                    if (comptime field.type == []u8) {
                                        unreachable;
                                        // @field(args, field.name) = A.allocator.dupe(arg);
                                    } else if (comptime field.type == []const u8) {
                                        @field(args, field.name) = arg;
                                    }
                                } else if (comptime p.is_const) {
                                    const tpl_arg = std.mem.bytesToValue(field.type, arg);
                                    @field(args, field.name) = tpl_arg;
                                }
                            },
                            else => {
                                const tpl_arg = std.mem.bytesToValue(field.type, arg);
                                @field(args, field.name) = tpl_arg;
                            },
                        }
                    }

                    const r = @call(.auto, f, args);
                    const frame = self.getCurrentFrame();
                    frame.ret_reg = try A.allocator.dupe(u8, std.mem.asBytes(&r));

                    return .cont;
                }
            }
        }

        std.log.err("extern symbol \"{s}\" not found", .{call_extern_fn.symbol});
        return error.ExternSymbolNotFound;
    }

    fn handleCallContinuation(self: *@This(), call_cont: IRInstruction.CallContinuation) !StepEvent {
        const continuation = std.mem.bytesToValue(
            Continuation,
            try self.evaluateValueGenericEnsureExists(call_cont.cont),
        );
        const payload = try self.evaluateValueGenericEnsureExists(call_cont.payload);

        return self.callCont(continuation, payload);
    }

    fn callCont(self: *@This(), continuation: Continuation, payload: IRValue) !StepEvent {
        for (continuation.saved_frames, 0..) |frame, i| {
            var cloned_frame = try frame.clone();
            if (i == 0) cloned_frame.ret_ip = .{ .abs_ = self.ip + 1 };
            try self.frames.append(A.allocator, cloned_frame);
        }
        const target_frame = self.getCurrentFrame();
        if (target_frame.payload) |old_payload| A.allocator.free(old_payload);
        target_frame.payload = try A.allocator.dupe(u8, payload);

        self.ip = continuation.saved_ip;

        return .cont_no_ip_inc;
    }

    fn handleUnwind(self: *@This(), unwind: IRInstruction.Unwind) !StepEvent {
        return switch (unwind.marker) {
            .handler => self.unwindHandler(unwind.value),
            .n_ => |n| self.unwindN(n, unwind.value),
        };
    }

    fn unwindHandler(self: *@This(), ret_value: IRValueGeneric) !StepEvent {
        const frame = self.getCurrentFrame();
        if (frame.effect_id) |effect_id| {
            const handler = self.findHandler(effect_id) orelse return error.InternalHandlerError;
            handler.saved_vm_fp = handler.original_fp;
            const frames_to_pop = self.frames.items.len - handler.original_fp;
            return self.unwindN(frames_to_pop, ret_value);
        }
        return error.UnwindOutsideOfEffectHandler;
    }

    fn unwindN(self: *@This(), n: usize, ret_value: IRValueGeneric) !StepEvent {
        const ret_value_ = try self.evaluateValueGenericEnsureExists(ret_value);
        if (n > 1) {
            for (0..n - 1) |_| {
                _ = self.popFrame();
            }
        }
        const frame_above = self.popFrame();
        self.ip = try self.evaluateInstructionPointer(frame_above.ret_ip);

        if (self.frames.items.len > 0) {
            const prev_frame = self.getCurrentFrame();
            prev_frame.ret_reg = ret_value_;
            return .cont_no_ip_inc;
        }

        return .{ .ret = ret_value_ };
    }

    fn handlePushFrame(self: *@This(), push_frame: IRInstruction.PushFrame) !StepEvent {
        try self.frames.append(A.allocator, .init(push_frame.label, .{ .abs_ = self.ip + 1 }));
        return .cont;
    }

    fn handlePushHandler(self: *@This(), push_handler: IRInstruction.PushHandler) !StepEvent {
        const frame = self.getCurrentFrame();
        try frame.pushHandler(.{
            .effect_id = push_handler.effect_id,
            .handler_ip = try self.evaluateInstructionPointer(push_handler.handler_ip),
            .saved_vm_fp = self.frames.items.len,
            .original_fp = self.frames.items.len,
        });
        // NOTE: 2 because of jmp instruction after that jumps to the inner scope
        try self.frames.append(A.allocator, .init("try_handle", .{ .abs_ = self.ip + 2 }));

        return .cont;
    }

    fn handlePopHandler(self: *@This(), pop_handler: IRInstruction.PopHandler) !StepEvent {
        const frame = self.getCurrentFrame();
        if (!frame.popHandler(pop_handler.effect_id)) return error.NoHandlerToPop;

        return .cont;
    }

    fn handlePerform(self: *@This(), perform: IRInstruction.Perform) !StepEvent {
        const handler = self.findHandler(perform.effect_id) orelse return error.UnhandledEffect;
        defer handler.saved_vm_fp += 1;

        var handler_frame = self.popFrame();

        const snapshot_frames = try self.dupeFrames(handler.saved_vm_fp);
        const continuation = try A.allocator.create(Continuation);
        continuation.* = .init(snapshot_frames, self.ip + 1);

        // for (self.frames.items[handler.saved_vm_fp..]) |*frame| frame.deinit();
        self.frames.shrinkRetainingCapacity(handler.saved_vm_fp);

        handler_frame.ret_ip = snapshot_frames[0].ret_ip;
        handler_frame.effect_id = perform.effect_id;
        handler_frame.operation = perform.operation;
        handler_frame.resume_ = continuation;

        try self.frames.append(A.allocator, handler_frame);

        self.ip = handler.handler_ip;

        return .cont_no_ip_inc;
    }

    // fn handlePerform(self: *@This(), perform: IRInstruction.Perform) !StepEvent {
    //     const handler = self.findHandler(perform.effect_id) orelse return error.UnhandledEffect;
    //     defer handler.saved_vm_fp += 1;
    //
    //     const snapshot_frames = try self.dupeFrames(handler.saved_vm_fp);
    //     const continuation = try A.allocator.create(Continuation);
    //     continuation.* = .init(snapshot_frames, self.ip + 1);
    //
    //     // for (self.frames.items[handler.saved_vm_fp..]) |*frame| frame.deinit();
    //     self.frames.shrinkRetainingCapacity(handler.saved_vm_fp);
    //
    //     var handler_frame = StackFrame.init("handler", snapshot_frames[0].ret_ip);
    //     const evaluated = try self.evaluateValueGenericEnsureExists(perform.arg_val);
    //     handler_frame.effect_id = perform.effect_id;
    //     handler_frame.operation = perform.operation;
    //     handler_frame.payload = try A.allocator.dupe(u8, evaluated);
    //     handler_frame.resume_ = continuation;
    //
    //     try self.frames.append(A.allocator, handler_frame);
    //
    //     self.ip = try self.evaluateInstructionPointer(handler.handler_ip);
    //
    //     return .cont_no_ip_inc;
    // }

    fn handleResume(
        self: *@This(),
        resume_: IRInstruction.Resume,
    ) !StepEvent {
        const handler_frame = self.getCurrentFrame();
        const continuation = handler_frame.resume_ orelse return error.NoContinuationInStackFrame;
        const payload = try self.evaluateValueGenericEnsureExists(resume_.value);

        return self.callCont(continuation.*, payload);
    }

    fn handlePrint(self: *@This(), print: IRInstruction.Print) !StepEvent {
        const value = try self.evaluateValueGenericEnsureExists(print.value);

        switch (print.fmt) {
            .string => std.log.debug("{s}", .{value}),
            .number => std.log.debug("{}", .{std.mem.bytesToValue(usize, value)}),
            .any => std.log.debug("{any}", .{value}),
        }

        return .cont;
    }

    fn handleBind(self: *@This(), bind: IRInstruction.Bind) !StepEvent {
        const evaluated = try self.evaluateValueGenericEnsureExists(bind.value);

        const frame = self.getCurrentFrame();
        try frame.map.put(bind.identifier, try A.allocator.dupe(u8, evaluated));

        return .cont;
    }

    fn getValueTarget(
        self: *@This(),
        target: IRInstruction.Set.Arg.Value.Target,
    ) !*IRValue {
        switch (target) {
            .identifier_ => |identifier| {
                const binding = self.lookupBinding(identifier) orelse {
                    std.log.err("identifier \"{s}\" not defined", .{identifier});
                    return error.IdentifierNotDefined;
                };

                return binding;
            },
            .ret_reg => {
                const frame = self.getCurrentFrame();
                return &frame.ret_reg;
            },
            .deref_ => |s| {
                return try self.evaluateDeref(.{ .value = &s.pointer }) orelse {
                    std.log.err("deref target {f} not found", .{s.pointer});
                    return error.DerefTargetNotFound;
                };
            },
        }
    }

    fn handleInc(self: *@This(), inc: IRInstruction.Inc) !StepEvent {
        const target = try self.getValueTarget(inc.target);
        var number: usize = std.mem.bytesToValue(usize, target.*);
        number +|= 1;
        const duped = try A.allocator.dupe(u8, std.mem.asBytes(&number));
        target.* = duped;
        return .cont;
    }

    fn handleDec(self: *@This(), dec: IRInstruction.Dec) !StepEvent {
        const target = try self.getValueTarget(dec.target);
        var number: usize = std.mem.bytesToValue(usize, target.*);
        number -|= 1;
        const duped = try A.allocator.dupe(u8, std.mem.asBytes(&number));
        target.* = duped;
        return .cont;
    }

    fn handleSet(self: *@This(), set: IRInstruction.Set) !StepEvent {
        switch (set.set_arg) {
            .ip_ => |s| {
                const ip = try self.evaluateInstructionPointer(s.value);

                switch (s.target) {
                    .ret_ip => {
                        const frame = self.getCurrentFrame();
                        frame.ret_ip = .abs(ip);
                    },
                }
            },
            .value_ => |s| {
                const evaluated = try self.evaluateValueGenericEnsureExists(s.value);
                const duped = try A.allocator.dupe(u8, evaluated);
                const target = try self.getValueTarget(s.target);
                target.* = duped;
            },
            .pop_frame_ => |s| {
                const frame = self.popFrame();
                const binding = self.lookupBinding(s.identifier) orelse {
                    std.log.err("identifier \"{s}\" not defined", .{s.identifier});
                    return error.IdentifierNotDefined;
                };

                // TODO: should we clone the frame as well?
                const value = try A.allocator.dupe(u8, std.mem.asBytes(&frame));

                binding.* = value;

                return .cont;
            },
            .f_ => |s| {
                switch (s.value) {
                    .function_ => |s_| {
                        const binding = self.lookupBinding(s.identifier) orelse {
                            std.log.err("identifier \"{s}\" not defined", .{s.identifier});
                            return error.IdentifierNotDefined;
                        };
                        const ip = try self.evaluateInstructionPointer(s_.ip);
                        binding.* = try A.allocator.dupe(u8, std.mem.asBytes(&ip));
                    },
                    .continuation_ => |s_| {
                        const binding = self.lookupBinding(s.identifier) orelse {
                            std.log.err("identifier \"{s}\" not defined", .{s.identifier});
                            return error.IdentifierNotDefined;
                        };
                        const evaluated_frames = try self.evaluateValueGenericEnsureExists(s_.stack_frames);
                        const frames = try A.allocator.dupe(u8, evaluated_frames);
                        const ip = try self.evaluateInstructionPointer(s_.ip);
                        const continuation = try A.allocator.create(Continuation);
                        continuation.* = .init(
                            @alignCast(std.mem.bytesAsSlice(StackFrame, frames)),
                            ip,
                        );
                        binding.* = std.mem.asBytes(continuation);
                    },
                }
            },
        }

        return .cont;
    }

    fn evaluateInstructionPointer(self: *@This(), ip: InstructionPointer) !usize {
        return switch (ip) {
            .abs_ => |s| s,
            .rel_ => |s| {
                const iip: isize = @intCast(self.ip);
                const result = iip + s;
                if (result < 0) {
                    self.log("ip less than zero", .{});
                    return error.InstructionPointerLessThanZero;
                }
                return @intCast(result);
            },
            .label_ => |s| self.labels.get(s) orelse {
                self.log("label {f} not defined", .{ip});
                return error.LabelNotDefined;
            },
            .value_ => |s| {
                const value = try self.evaluateValueGenericEnsureExists(s.*);
                return std.mem.bytesToValue(usize, value);
            },
        };
    }

    pub const EvaluateValueError = error{
        InstructionPointerLessThanZero,
        FramePointerLessThanZero,
        ResumeNotDefined,
        DerefTargetNotFound,
        LabelNotDefined,
        CantFindValue,
    } || Allocator.Error;

    fn evaluateValueGeneric(self: *@This(), value: IRValueGeneric) EvaluateValueError!?IRValue {
        return switch (value) {
            .literal_ => |s| s,
            .identifier_ => |s| self.lookup(s),
            .pointer_ => |s| self.evaluatePointer(s),
            .ath_ => |s| self.evaluateAth(s),
            .deref_ => |s| {
                const target = try self.evaluateDeref(s) orelse return null;
                return target.*;
            },
            .operation => self.getCurrentFrame().operation,
            .payload => self.getCurrentFrame().payload,
            .resume_ => {
                const resume_ = self.getCurrentFrame().resume_ orelse {
                    std.log.err("%resume not defined", .{});
                    return error.ResumeNotDefined;
                };

                return std.mem.asBytes(resume_);
            },
            .ret_reg => self.getCurrentFrame().ret_reg,
            .pop_frame => {
                const frame = self.popFrame();
                return try A.allocator.dupe(u8, std.mem.asBytes(&frame));
            },
            .function_ => |s| {
                const ip = try self.evaluateInstructionPointer(s.ip);
                return try A.allocator.dupe(u8, std.mem.asBytes(&ip));
            },
            .continuation_ => |s| {
                const frames = try self.evaluateValueGenericEnsureExists(s.stack_frames);
                const ip = try self.evaluateInstructionPointer(s.ip);
                const continuation = Continuation.init(@ptrCast(@alignCast(frames)), ip);
                return try A.allocator.dupe(u8, std.mem.asBytes(&continuation));
            },
            .void_ => &.{},
        };
    }

    fn evaluatePointer(self: *@This(), pointer: IRValueGeneric.Pointer) !?IRValue {
        const mod: isize = switch (pointer.mod) {
            .none => 0,
            .add_ => |s| s,
        };
        _ = mod;
        switch (pointer.addr) {
            .stack => |s| {
                const fp: usize = switch (s.fp) {
                    .abs_ => |s_| s_,
                    .rel_ => |s_| brk: {
                        const ifp: isize = @intCast(self.frames.items.len);
                        const result = ifp + s_ - 1;
                        if (result < 0) {
                            self.log("fp less than zero", .{});
                            return error.FramePointerLessThanZero;
                        }
                        break :brk @intCast(result);
                    },
                };
                const abs_pointer = IRValueGeneric.Pointer.stack(.abs(fp), s.identifier);
                const duped = try A.allocator.dupe(u8, std.mem.asBytes(&abs_pointer));
                return duped;
            },
        }
    }

    fn evaluateAth(self: *@This(), ath: IRValueGeneric.Ath) !?IRValue {
        const lhs = try self.evaluateValueGeneric(ath.lhs.*) orelse return null;
        const rhs = try self.evaluateValueGeneric(ath.rhs.*) orelse return null;

        return try switch (ath.type) {
            .u8 => self.evaluateAthWithType(u8, lhs, rhs, ath.op),
            .u32 => self.evaluateAthWithType(u32, lhs, rhs, ath.op),
            .i32 => self.evaluateAthWithType(i32, lhs, rhs, ath.op),
        };
    }

    fn evaluateAthWithType(
        _: *@This(),
        comptime T: type,
        lhs: IRValue,
        rhs: IRValue,
        op: IRValueGeneric.Ath.Op,
    ) !IRValue {
        const lhs_ = std.mem.bytesToValue(T, lhs);
        const rhs_ = std.mem.bytesToValue(T, rhs);
        const result = switch (op) {
            .add => lhs_ + rhs_,
            .sub => lhs_ - rhs_,
        };
        return try A.allocator.dupe(u8, std.mem.asBytes(&result));
    }

    fn evaluateDeref(self: *@This(), deref: IRValueGeneric.Deref) !?*IRValue {
        const value = try self.evaluateValueGeneric(deref.value.*) orelse return null;
        const pointer = std.mem.bytesToValue(IRValueGeneric.Pointer, value);

        switch (pointer.addr) {
            .stack => |stack| {
                switch (stack.fp) {
                    .abs_ => |fp| {
                        const frame = self.frames.items[fp];
                        return frame.map.getPtr(stack.identifier);
                    },
                    .rel_ => unreachable,
                }
            },
        }
    }

    fn evaluateValueGenericEnsureExists(self: *@This(), value: IRValueGeneric) !IRValue {
        const evaluated = try self.evaluateValueGeneric(value) orelse {
            self.log("Couldn't find value {f}", .{value});
            return error.CantFindValue;
        };

        return evaluated;
    }

    // TODO: Should we limit only to the current frame to avoid grabbing locals from outside scopes?
    pub fn lookup(self: *@This(), identifier: []const u8) ?IRValue {
        if (self.lookupBinding(identifier)) |binding| return binding.*;
        return null;
    }

    pub fn lookupBinding(self: *@This(), identifier: []const u8) ?*IRValue {
        var frame_index = self.frames.items.len;
        while (frame_index > 0) {
            frame_index -= 1;
            const frame = &self.frames.items[frame_index];
            if (frame.map.getPtr(identifier)) |value| {
                return value;
            }
        }

        return null;
    }

    fn getCurrentFrame(self: *@This()) *StackFrame {
        std.debug.assert(self.frames.items.len > 0);
        return &self.frames.items[self.frames.items.len - 1];
    }

    fn popFrame(self: *@This()) StackFrame {
        std.debug.assert(self.frames.items.len > 0);
        return self.frames.pop().?;
    }
};

pub const IRInstruction = struct {
    instruction_type: Type,

    pub fn init(instruction_type: Type) @This() {
        return .{ .instruction_type = instruction_type };
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{f}", .{self.instruction_type});
    }

    pub const Jump = struct {
        ip: InstructionPointer,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("jmp to:{f}", .{self.ip});
        }
    };

    pub const JumpIfEqual = struct {
        lhs: IRValueGeneric,
        rhs: IRValueGeneric,
        ip: InstructionPointer,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("jeq {f}={f} to:{f}", .{ self.lhs, self.rhs, self.ip });
        }
    };

    pub const JumpIfNotEqual = struct {
        lhs: IRValueGeneric,
        rhs: IRValueGeneric,
        ip: InstructionPointer,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("jneq {f}={f} to:{f}", .{ self.lhs, self.rhs, self.ip });
        }
    };

    pub const JumpIfEqualZero = struct {
        value: IRValueGeneric,
        ip: InstructionPointer,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("jz {f} to:{f}", .{ self.value, self.ip });
        }
    };

    pub const JumpIfNotEqualZero = struct {
        value: IRValueGeneric,
        ip: InstructionPointer,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("jnz {f} to:{f}", .{ self.value, self.ip });
        }
    };

    pub const CallExternFunction = struct {
        symbol: []const u8,
        args: []const IRValueGeneric,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("call_extern_fn {s} ({})", .{ self.symbol, self.args.len });
        }
    };

    pub const CallContinuation = struct {
        cont: IRValueGeneric,
        payload: IRValueGeneric,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("call_cont {f}({f})", .{ self.cont, self.payload });
        }
    };

    pub const Return = struct {
        value: IRValueGeneric = .void_,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("ret {f}", .{self.value});
        }
    };

    pub const Unwind = struct {
        marker: Marker,
        value: IRValueGeneric = .void_,

        pub const Marker = union(enum) {
            handler,
            n_: usize,

            pub fn n(n_: usize) @This() {
                return .{ .n_ = n_ };
            }
        };

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try switch (self.marker) {
                .handler => writer.print("unwind {f}", .{self.value}),
                .n_ => |n| {
                    if (n == 1) {
                        try writer.print("ret {f}", .{self.value});
                    } else {
                        try writer.print("unwind n:{} {f}", .{ n, self.value });
                    }
                },
            };
        }
    };

    pub const Bind = struct {
        identifier: []const u8,
        value: IRValueGeneric,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("bind {s}={f}", .{ self.identifier, self.value });
        }
    };

    pub const Inc = struct {
        target: Set.Arg.Value.Target,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("inc {f}", .{self.target});
        }
    };

    pub const Dec = struct {
        target: Set.Arg.Value.Target,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("dec {f}", .{self.target});
        }
    };

    pub const Set = struct {
        set_arg: Arg,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("set {f}", .{self.set_arg});
        }

        pub const Arg = union(enum) {
            ip_: Ip,
            value_: Value,
            pop_frame_: PopFrame,
            f_: Function,

            pub fn ip(target: Ip.Target, value_: Ip.Value) @This() {
                return .{ .ip_ = .{ .target = target, .value = value_ } };
            }

            pub fn value(target: Value.Target, value_: Value.Value) @This() {
                return .{ .value_ = .{ .target = target, .value = value_ } };
            }

            pub fn popFrame(identifier: []const u8) @This() {
                return .{ .pop_frame_ = .{ .identifier = identifier } };
            }

            pub fn f(identifier: []const u8, value_: Function.Value) @This() {
                return .{ .f_ = .{ .identifier = identifier, .value = value_ } };
            }

            pub fn format(
                self: @This(),
                writer: *std.Io.Writer,
            ) std.Io.Writer.Error!void {
                switch (self) {
                    inline else => |s| try writer.print("{f}", .{s}),
                }
            }

            pub const Ip = struct {
                target: Target,
                value: @This().Value,

                pub fn format(
                    self: @This(),
                    writer: *std.Io.Writer,
                ) std.Io.Writer.Error!void {
                    try writer.print("{t} = {f}", .{ self.target, self.value });
                }

                pub const Target = enum { ret_ip };
                pub const Value = InstructionPointer;
            };

            pub const Value = struct {
                target: Target,
                value: @This().Value,

                pub fn format(
                    self: @This(),
                    writer: *std.Io.Writer,
                ) std.Io.Writer.Error!void {
                    try writer.print("{f} = {f}", .{ self.target, self.value });
                }

                pub const Target = union(enum) {
                    identifier_: []const u8,
                    deref_: Deref,
                    ret_reg,

                    pub fn identifier(identifier_: []const u8) @This() {
                        return .{ .identifier_ = identifier_ };
                    }

                    pub fn deref(pointer: IRValueGeneric) @This() {
                        return .{ .deref_ = .{ .pointer = pointer } };
                    }

                    pub fn format(
                        self: @This(),
                        writer: *std.Io.Writer,
                    ) std.Io.Writer.Error!void {
                        try switch (self) {
                            .identifier_ => |s| writer.print("@{s}", .{s}),
                            .ret_reg => writer.print("#ret_reg", .{}),
                            .deref_ => |s| writer.print("{f}.*", .{s.pointer}),
                        };
                    }

                    pub const Deref = struct {
                        pointer: IRValueGeneric,
                    };
                };

                pub const Value = IRValueGeneric;
            };

            pub const PopFrame = struct {
                identifier: []const u8,

                pub fn format(
                    self: @This(),
                    writer: *std.Io.Writer,
                ) std.Io.Writer.Error!void {
                    try writer.print("@{s} = pop_frame", .{self.identifier});
                }
            };

            pub const Function = struct {
                identifier: []const u8,
                value: @This().Value,

                pub fn format(
                    self: @This(),
                    writer: *std.Io.Writer,
                ) std.Io.Writer.Error!void {
                    try writer.print("@{s} = {f}", .{ self.identifier, self.value });
                }

                pub const Value = union(enum) {
                    function_: @This().Function,
                    continuation_: @This().Continuation,

                    pub fn function(
                        ip_: InstructionPointer,
                    ) @This() {
                        return .{ .function_ = .{
                            .ip = ip_,
                        } };
                    }

                    pub fn continuation(
                        stack_frames: IRValueGeneric,
                        ip_: InstructionPointer,
                    ) @This() {
                        return .{ .continuation_ = .{
                            .stack_frames = stack_frames,
                            .ip = ip_,
                        } };
                    }

                    pub fn format(
                        self: @This(),
                        writer: *std.Io.Writer,
                    ) std.Io.Writer.Error!void {
                        switch (self) {
                            inline else => |s| try writer.print("{f}", .{s}),
                        }
                    }

                    pub const Function = struct {
                        ip: InstructionPointer,

                        pub fn format(
                            self: @This(),
                            writer: *std.Io.Writer,
                        ) std.Io.Writer.Error!void {
                            try writer.print("fn:{f}", .{self.ip});
                        }
                    };

                    pub const Continuation = struct {
                        stack_frames: IRValueGeneric,
                        ip: InstructionPointer,

                        pub fn format(
                            self: @This(),
                            writer: *std.Io.Writer,
                        ) std.Io.Writer.Error!void {
                            try writer.print("cont_fn:{f}", .{self.ip});
                        }
                    };
                };
            };
        };
    };

    pub const PushFrame = struct {
        label: []const u8,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("push_frame \"{s}\"", .{self.label});
        }
    };

    pub const PushHandler = struct {
        effect_id: EffectId,
        handler_ip: InstructionPointer,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("push_handler effect_id:{} handler_ip:{f}", .{ self.effect_id, self.handler_ip });
        }
    };

    pub const PopHandler = struct {
        effect_id: EffectId,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("pop_handler effect_id:{}", .{self.effect_id});
        }
    };

    pub const Perform = struct {
        effect_id: EffectId,
        operation: []const u8,
        // arg_val: IRValueGeneric = .void_,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            // try writer.print("perform effect_id:{} op:{s} arg:{f}", .{ self.effect_id, self.operation, self.arg_val });
            try writer.print("perform effect_id:{} op:{s}", .{ self.effect_id, self.operation });
        }
    };

    pub const Resume = struct {
        value: IRValueGeneric = .void_,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("resume arg:{f}", .{self.value});
        }
    };

    pub const Print = struct {
        fmt: Format = .any,
        value: IRValueGeneric,

        pub fn init(fmt: Format, value: IRValueGeneric) @This() {
            return .{ .fmt = fmt, .value = value };
        }

        pub const Format = enum { string, number, any };

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("print {f}", .{self.value});
        }
    };

    pub const Type = union(enum) {
        jmp_: Jump,
        jeq_: JumpIfEqual,
        jneq_: JumpIfNotEqual,
        jz_: JumpIfEqualZero,
        jnz_: JumpIfNotEqualZero,
        call_extern_fn: CallExternFunction,
        call_cont: CallContinuation,
        unwind_: Unwind,
        push_frame_: PushFrame,
        push_handler: PushHandler,
        pop_handler: PopHandler,
        perform_: Perform,
        resume__: Resume,
        bind_: Bind,
        inc_: Inc,
        dec_: Dec,
        set_: Set,
        print_: Print,

        pub fn jmp(ip: InstructionPointer) @This() {
            return .{ .jmp_ = .{ .ip = ip } };
        }

        pub fn jeq(
            lhs: IRValueGeneric,
            rhs: IRValueGeneric,
            ip: InstructionPointer,
        ) @This() {
            return .{ .jeq_ = .{ .lhs = lhs, .rhs = rhs, .ip = ip } };
        }

        pub fn jneq(
            lhs: IRValueGeneric,
            rhs: IRValueGeneric,
            ip: InstructionPointer,
        ) @This() {
            return .{ .jneq_ = .{ .lhs = lhs, .rhs = rhs, .ip = ip } };
        }

        pub fn jz(
            value: IRValueGeneric,
            ip: InstructionPointer,
        ) @This() {
            return .{ .jz_ = .{ .value = value, .ip = ip } };
        }

        pub fn jnz(
            value: IRValueGeneric,
            ip: InstructionPointer,
        ) @This() {
            return .{ .jnz_ = .{ .value = value, .ip = ip } };
        }

        pub fn ret(value: IRValueGeneric) @This() {
            return .unwind(.n(1), value);
        }

        pub fn unwind(marker: Unwind.Marker, value: IRValueGeneric) @This() {
            return .{ .unwind_ = .{ .marker = marker, .value = value } };
        }

        pub fn callExternFn(symbol: []const u8, args: []const IRValueGeneric) @This() {
            return .{ .call_extern_fn = .{ .symbol = symbol, .args = args } };
        }

        pub fn callCont(continuation: IRValueGeneric, payload: IRValueGeneric) @This() {
            return .{ .call_cont = .{ .cont = continuation, .payload = payload } };
        }

        pub fn pushFrame(label: []const u8) @This() {
            return .{ .push_frame_ = .{ .label = label } };
        }

        pub fn pushHandler(
            effect_id: EffectId,
            handler_ip: InstructionPointer,
        ) @This() {
            return .{ .push_handler = .{
                .effect_id = effect_id,
                .handler_ip = handler_ip,
            } };
        }

        pub fn popHandler(effect_id: EffectId) @This() {
            return .{ .pop_handler = .{ .effect_id = effect_id } };
        }

        pub fn bind(identifier: []const u8, value: IRValueGeneric) @This() {
            return .{ .bind_ = .{ .identifier = identifier, .value = value } };
        }

        pub fn inc(target: Set.Arg.Value.Target) @This() {
            return .{ .inc_ = .{ .target = target } };
        }

        pub fn dec(target: Set.Arg.Value.Target) @This() {
            return .{ .dec_ = .{ .target = target } };
        }

        pub fn set(set_arg: Set.Arg) @This() {
            return .{ .set_ = .{ .set_arg = set_arg } };
        }

        pub fn perform(
            effect_id: EffectId,
            operation: []const u8,
            // arg_val: IRValueGeneric,
        ) @This() {
            return .{
                .perform_ = .{
                    .effect_id = effect_id,
                    .operation = operation,
                    // .arg_val = arg_val,
                },
            };
        }

        pub fn resume_(value: IRValueGeneric) @This() {
            return .{ .resume__ = .{ .value = value } };
        }

        pub fn print(fmt: Print.Format, value: IRValueGeneric) @This() {
            return .{ .print_ = .init(fmt, value) };
        }

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            switch (self) {
                inline else => |s| try writer.print("{f}", .{s}),
            }
        }
    };
};
