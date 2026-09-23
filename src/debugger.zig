const std = @import("std");
const A = @import("allocator.zig");
const VM = @import("effect-vm.zig").VM;
const IRValueConst = @import("effect-vm.zig").IRValueConst;
const Token = @import("tokenizer.zig").Tokenizer.Token;

pub const Debugger = struct {
    vm: *VM,
    breakpoints: std.AutoHashMapUnmanaged(Breakpoint, void) = .empty,
    source_map: []const Token,

    pub fn init(vm: *VM, source_map: []const Token) @This() {
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

    pub fn readAndExecuteCommand(
        self: *@This(),
        reader: *std.Io.Reader,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !DebuggerEvent {
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
            try self.toggleBreakpoint(stdout, n);
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

        const min_ip = self.vm.ip -| 3;
        const max_ip = @min(self.vm.ip +| 3, self.vm.instructions.len - 1);

        for (min_ip..max_ip) |ip| try self.printSrcInstruction(writer, ip);
    }

    pub fn printSrcInstruction(self: *@This(), writer: *std.Io.Writer, ip: usize) !void {
        var prefix: [3]u8 = .{' '} ** 3;
        if (ip == self.vm.ip) prefix[1] = '>';
        if (self.breakpoints.contains(.init(ip))) prefix[0] = 'B';
        try writer.print("{s}[{}]{f}\n", .{ prefix, ip, self.vm.instructions[ip] });
    }

    pub fn toggleBreakpoint(self: *@This(), stdout: *std.Io.Writer, line: usize) !void {
        const bp = self.mkBreakpoint(line);
        if (self.breakpoints.contains(bp)) {
            self.removeBreakpoint(line);
            try stdout.writeAll("removed breakpoint at:\n");
            try self.printSrcInstruction(stdout, bp.ip);
        } else {
            try self.addBreakpoint(line);
            try stdout.writeAll("added breakpoint at:\n");
            try self.printSrcInstruction(stdout, bp.ip);
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

        pub fn fromLine(line: usize, source_map: []const Token) @This() {
            var ip: usize = 0;
            for (source_map) |tok| {
                if (tok.srcLine() == line) break;
                ip += 1;
            }
            return .init(ip);
        }
    };

    pub const DebuggerEvent = union(enum) {
        err,
        finished: IRValueConst,
        paused,
    };
};
