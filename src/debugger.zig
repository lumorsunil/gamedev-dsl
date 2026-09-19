const std = @import("std");
const A = @import("allocator.zig");
const VM = @import("effect-vm.zig").VM;
const IRValue = @import("effect-vm.zig").IRValue;

pub const Debugger = struct {
    vm: *VM,
    breakpoints: std.AutoHashMapUnmanaged(Breakpoint, void) = .empty,
    source_map: []const usize,

    pub fn init(vm: *VM, source_map: []const usize) @This() {
        return .{ .vm = vm, .source_map = source_map };
    }

    pub fn continue_(self: *@This()) DebuggerEvent {
        while (true) {
            const e = self.step();

            switch (e) {
                .paused => {
                    if (self.breakpoints.contains(.init(self.vm.ip))) {
                        return .paused;
                    }
                    continue;
                },
                .finished, .err => return e,
            }
        }
    }

    pub fn step(self: *@This()) DebuggerEvent {
        const event = self.vm.step() catch |err| {
            std.log.debug("VM error: {}", .{err});
            return .err;
        };

        switch (event) {
            .cont => self.vm.ip += 1,
            .cont_no_ip_inc => {},
            .ret => |s| return .{ .finished = s },
        }

        return .paused;
    }

    pub fn readAndExecuteCommand(self: *@This(), reader: *std.Io.Reader, stderr: *std.Io.Writer) !DebuggerEvent {
        var line: []const u8 = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            std.Io.Reader.DelimiterError.EndOfStream => {
                try stderr.print("stdin closed", .{});
                return .err;
            },
            else => {
                try stderr.print("error reading stdin: {}", .{err});
                return .err;
            },
        };
        reader.toss(1);
        line = std.mem.trim(u8, line, "\r");

        try stderr.print("\n", .{});

        if (std.mem.eql(u8, line, "step")) {
            return self.step();
        } else if (std.mem.eql(u8, line, "continue")) {
            return self.continue_();
        } else if (std.mem.eql(u8, line, "quit")) {
            return .{ .finished = &.{} };
        } else if (std.mem.startsWith(u8, line, "bp ")) {
            var it = std.mem.splitScalar(u8, line, ' ');
            _ = it.next();
            const n_s = it.next() orelse {
                try stderr.print("usage: bp <line>\n", .{});
                return .paused;
            };
            const n = std.fmt.parseInt(usize, n_s, 10) catch |err| {
                try stderr.print("error: {}\n", .{err});
                try stderr.print("usage: bp <line>\n", .{});
                return .paused;
            };
            try self.toggleBreakpoint(n);
            return .paused;
        } else {
            try stderr.print("unknown command \"{s}\"\n", .{line});
            try stderr.print("available commands:\n", .{});
            try stderr.print("step\t\tSteps one instruction.\n", .{});
            try stderr.print("continue\tContinues until end or breakpoint.\n", .{});
            try stderr.print("bp <line>\tToggles breakpoint.\n", .{});
            return .paused;
        }
    }

    pub fn printContext(self: *@This(), writer: *std.Io.Writer) !void {
        for (self.vm.frames.items, 0..) |frame, i| {
            try writer.print("${}: {f}\n", .{ i, frame });
        }

        const min_line = self.vm.ip -| 3;
        const max_line = @min(self.vm.ip +| 3, self.vm.instructions.len - 1);

        for (min_line..max_line) |i| {
            var prefix: [3]u8 = .{' '} ** 3;
            if (i == self.vm.ip) prefix[1] = '>';
            if (self.breakpoints.contains(.init(i))) prefix[0] = 'B';
            try writer.print("{s}[{}]{f}\n", .{ prefix, i, self.vm.instructions[i] });
        }
    }

    pub fn toggleBreakpoint(self: *@This(), line: usize) !void {
        if (self.breakpoints.contains(self.mkBreakpoint(line))) {
            self.removeBreakpoint(line);
        } else {
            try self.addBreakpoint(line);
        }
    }

    pub fn addBreakpoint(self: *@This(), line: usize) !void {
        try self.breakpoints.put(A.allocator, self.mkBreakpoint(line), {});
    }

    pub fn removeBreakpoint(self: *@This(), line: usize) void {
        _ = self.breakpoints.remove(self.mkBreakpoint(line));
    }

    pub fn mkBreakpoint(self: @This(), line: usize) Breakpoint {
        return .fromLine(line, self.source_map);
    }

    pub const Breakpoint = struct {
        ip: usize,

        pub fn init(ip: usize) @This() {
            return .{ .ip = ip };
        }

        pub fn fromLine(line: usize, source_map: []const usize) @This() {
            const ip = std.mem.findScalar(usize, source_map, line).?;
            return .init(ip);
        }
    };

    pub const DebuggerEvent = union(enum) {
        err,
        finished: IRValue,
        paused,
    };
};
