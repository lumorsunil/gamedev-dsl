const std = @import("std");
const Value = @import("value.zig").Value;
const A = @import("allocator.zig");

const IRValue = []u8;
const IRValueConst = []const u8;
const EffectId = usize;
const InstructionPointer = union(enum) {
    abs: usize,
    rel: usize,
    label: Label,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try switch (self) {
            .abs => |s| writer.print("#{}", .{s}),
            .rel => |s| writer.print("#+{}", .{s}),
            .label => |s| writer.print("#L{s}.{t}", .{ s.identifier, s.type }),
        };
    }

    pub const Label = struct {
        identifier: []const u8,
        type: Type = .label,

        pub const Type = enum {
            label,
            start_of_fn,
            end_of_fn,
        };
    };
};

pub const IRValueGeneric = union(enum) {
    literal: IRValueConst,
    identifier: []const u8,
    operation,
    payload,
    void_,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .literal => |s| try writer.print("literal({})", .{s.len}),
            .identifier => |s| try writer.print("@{s}", .{s}),
            .operation => try writer.writeAll("%operation"),
            .payload => try writer.writeAll("%payload"),
            .void_ => try writer.writeAll("void"),
        }
    }
};

pub const StackFrame = struct {
    ip: InstructionPointer,
    handlers: std.ArrayList(Handler) = .empty,
    map: std.StringHashMap(V),
    continuations: std.ArrayList(*Continuation) = .empty,

    // Handler frame fields
    operation: ?IRValueConst = null,
    payload: ?IRValue = null,
    resume_: ?*Continuation = null,

    pub const K = []const u8;
    pub const V = IRValue;

    pub fn init(ip: InstructionPointer) @This() {
        return .{ .ip = ip, .map = .init(A.allocator) };
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
};

pub const Handler = struct {
    effect_id: EffectId,
    handler_ip: InstructionPointer,
    saved_vm_fp: usize,
};

pub const Continuation = struct {
    saved_frames: []StackFrame,
    saved_ip: usize,

    pub fn init(frames: []StackFrame, saved_ip: usize) @This() {
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
    labels: std.AutoHashMap(InstructionPointer.Label, usize),

    pub fn init(
        instructions: []const IRInstruction,
        labels: std.AutoHashMap(InstructionPointer.Label, usize),
    ) !@This() {
        return .{
            .instructions = instructions,
            .labels = try labels.clone(),
        };
    }

    pub fn deinit(self: *@This()) void {
        for (self.frames.items) |*frame| frame.deinit();
        self.frames.deinit(A.allocator);
    }

    pub fn run(self: *@This()) !void {
        try self.frames.append(A.allocator, .init(std.math.maxInt(usize)));
        while (self.ip < self.instructions.len) {
            switch (try self.step()) {
                .cont => {
                    self.ip += 1;
                    continue;
                },
                .cont_no_ip_inc => continue,
            }
        }
    }

    pub const StepEvent = enum {
        cont,
        cont_no_ip_inc,
    };

    pub fn step(self: *@This()) !StepEvent {
        const instruction = self.instructions[self.ip];

        self.logCurrentInstruction();

        return switch (instruction.instruction_type) {
            .jmp => |s| self.handleJump(s),
            .jeq => |s| self.handleJumpIfEqual(s),
            .ret => self.handleReturn(),
            .push_handler => |s| self.handlePushHandler(s),
            .pop_handler => |s| self.handlePopHandler(s),
            .perform => |s| self.handlePerform(s),
            .resume_ => |s| self.handleResume(s),
            .bind => |s| self.handleBind(s),
            .print => |s| self.handlePrint(s),
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

        self.log("lhs={any}", .{lhs});
        self.log("rhs={any}", .{rhs});

        if (std.mem.eql(u8, lhs, rhs)) {
            self.ip = try self.evaluateInstructionPointer(jeq.ip);
            return .cont_no_ip_inc;
        }

        return .cont;
    }

    fn handleReturn(self: *@This()) !StepEvent {
        var frame = self.popFrame();
        self.ip = try self.evaluateInstructionPointer(frame.ip);
        frame.deinit();
        if (frame.resume_) |resume_| resume_.deinit();
        return .cont_no_ip_inc;
    }

    fn handlePushHandler(self: *@This(), push_handler: IRInstruction.PushHandler) !StepEvent {
        const frame = self.getCurrentFrame();
        try frame.pushHandler(.{
            .effect_id = push_handler.effect_id,
            .handler_ip = push_handler.handler_ip,
            .saved_vm_fp = self.frames.items.len,
        });
        // NOTE: 2 because of jmp instruction after that jumps to the inner scope
        self.frames.append(A.allocator, .init(.{ .abs = self.ip + 2 }));

        return .cont;
    }

    fn handlePopHandler(self: *@This(), pop_handler: IRInstruction.PopHandler) !StepEvent {
        const frame = self.getCurrentFrame();
        if (!frame.popHandler(pop_handler.effect_id)) return error.NoHandlerToPop;

        return .cont;
    }

    fn handlePerform(self: *@This(), perform: IRInstruction.Perform) !StepEvent {
        const handler = self.findHandler(perform.effect_id) orelse return error.UnhandledEffect;

        // [0] main_frame
        //
        // PUSH_HANDLER State
        //
        // [0] main_frame
        // [1] main_frame__state (ret ip: end of main_frame)
        //
        // PERFORM State.set(42)
        //
        // [0] main_frame
        // [1] handler_frame (ret ip: end of main_frame)
        //
        // SET main_frame.@state = 42
        //
        // [0] main_frame (@state = 42)
        // [1] handler_frame (ret ip: end of main_frame)
        //
        // RESUME
        //
        // [0] main_frame (@state = 42)
        // [1] handler_frame (ret ip: end of main_frame)
        // [2] main_frame__state_clone (ret ip: handler_frame.set: after resume)
        //
        // PERFORM State.get()
        //
        // [0] main_frame
        // [1] handler_frame_2 (ret ip: end of main_frame)
        //
        // RESUME
        //
        // [0] main_frame
        // [1] handler_frame_2 (ret ip: end of main_frame)
        // [2] handler_frame_clone (ret ip: handler_frame.get: after resume)
        // [3] main_frame__state_clone_2 (ret ip: handler_frame.set after resume)
        //
        // OUT OF SCOPE/RETURN (try/handle scope)
        //
        // [0] main_frame
        // [1] handler_frame_2 (42)
        // [2] handler_frame (42)
        //
        // State.get() continues
        //
        // RETURN
        //
        // [0] main_frame
        // [1] handler_frame (42)
        //
        // State.set() continues
        //
        // RETURN
        //
        // [0] main_frame
        //
        // RETURN

        const snapshot_frames = try self.dupeFrames(handler.saved_vm_fp);
        const continuation = try A.allocator.create(Continuation);
        continuation.* = .init(snapshot_frames, self.ip + 1);

        for (self.frames.items[handler.saved_vm_fp..]) |*frame| frame.deinit();
        self.frames.shrinkRetainingCapacity(handler.saved_vm_fp);

        var handler_frame = StackFrame.init(handler.handler_ip);
        const evaluated = try self.evaluateValueGenericEnsureExists(perform.arg_val);
        handler_frame.operation = perform.operation;
        handler_frame.payload = try A.allocator.dupe(u8, evaluated);
        handler_frame.resume_ = continuation;

        try self.frames.append(A.allocator, handler_frame);

        self.ip = try self.evaluateInstructionPointer(handler_frame.ip);

        return .cont_no_ip_inc;
    }

    fn handleResume(
        self: *@This(),
        resume_: IRInstruction.Resume,
    ) !StepEvent {
        const handler_frame = self.getCurrentFrame();
        const continuation = handler_frame.resume_ orelse return error.NoContinuationInStackFrame;
        for (continuation.saved_frames) |frame| {
            try self.frames.append(A.allocator, try frame.clone());
        }
        const target_frame = self.getCurrentFrame();
        if (target_frame.payload) |old_payload| A.allocator.free(old_payload);
        const evaluated = try self.evaluateValueGenericEnsureExists(resume_.value);
        target_frame.payload = try A.allocator.dupe(u8, evaluated);

        self.ip = continuation.saved_ip;

        return .cont_no_ip_inc;
    }

    fn handlePrint(self: *@This(), print: IRInstruction.Print) !StepEvent {
        const value = try self.evaluateValueGenericEnsureExists(print.value);
        std.log.debug("{any}", .{value});

        return .cont;
    }

    fn handleBind(self: *@This(), bind: IRInstruction.Bind) !StepEvent {
        const frame = self.getCurrentFrame();
        const evaluated = try self.evaluateValueGenericEnsureExists(bind.value);
        try frame.map.put(bind.identifier, try A.allocator.dupe(u8, evaluated));

        return .cont;
    }

    fn evaluateInstructionPointer(self: *@This(), ip: InstructionPointer) !usize {
        return switch (ip) {
            .abs => |s| s,
            .rel => |s| self.ip + s,
            .label => |s| self.labels.get(s) orelse {
                self.log("label \"{s}\" ({t}) not defined", .{ s.identifier, s.type });
                return error.LabelNotDefined;
            },
        };
    }

    fn evaluateValueGeneric(self: *@This(), value: IRValueGeneric) ?IRValueConst {
        return switch (value) {
            .literal => |s| s,
            .identifier => |s| self.lookup(s),
            .operation => self.getCurrentFrame().operation,
            .payload => self.getCurrentFrame().payload,
            .void_ => &.{},
        };
    }

    fn evaluateValueGenericEnsureExists(self: *@This(), value: IRValueGeneric) !IRValueConst {
        const evaluated = self.evaluateValueGeneric(value) orelse {
            self.log("Couldn't find value {f}", .{value});
            return error.CantFindValue;
        };

        return evaluated;
    }

    // TODO: Should we limit only to the current frame to avoid grabbing locals from outside scopes?
    pub fn lookup(self: *@This(), identifier: []const u8) ?IRValue {
        var frame_index = self.frames.items.len;
        while (frame_index > 0) {
            frame_index -= 1;
            const frame = &self.frames.items[frame_index];
            if (frame.map.get(identifier)) |value| {
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

    pub const Return = struct {
        pub fn format(
            _: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("ret", .{});
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
        arg_val: IRValueGeneric,
        operation: []const u8,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("perform effect_id:{} op:{s} arg:{f}", .{ self.effect_id, self.operation, self.arg_val });
        }
    };

    pub const Resume = struct {
        value: IRValueGeneric,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("resume arg:{f}", .{self.value});
        }
    };

    pub const Print = struct {
        value: IRValueGeneric,

        pub fn format(
            self: @This(),
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try writer.print("print {f}", .{self.value});
        }
    };

    pub const Type = union(enum) {
        jmp: Jump,
        jeq: JumpIfEqual,
        ret: Return,
        push_handler: PushHandler,
        pop_handler: PopHandler,
        perform: Perform,
        resume_: Resume,
        bind: Bind,
        print: Print,

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
