const std = @import("std");
const VM = @import("effect-vm.zig").VM;
const IRInstruction = @import("effect-vm.zig").IRInstruction;
const InstructionPointer = @import("effect-vm.zig").InstructionPointer;
const Debugger = @import("debugger.zig").Debugger;
const A = @import("allocator.zig");
const Token = @import("tokenizer.zig").Tokenizer.Token;

pub fn main(init: std.process.Init) !void {
    A.allocator = init.arena.allocator();
    A.page = init.gpa;

    const t0 = std.Io.Clock.now(.real, init.io);

    const source_file_name = "src/raylib.eftir";
    std.log.debug("compiling and running {s}", .{source_file_name});
    std.log.debug("reading file {s}...", .{source_file_name});
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, source_file_name, A.allocator, .unlimited);
    std.log.debug("read file {s} in {f}", .{ source_file_name, t0.untilNow(init.io, .real) });
    std.log.debug("compiling source...", .{});

    var parser = @import("effective-ir-parser.zig").Parser.init(source);
    var instructions = std.ArrayList(IRInstruction).empty;
    var instruction_idx: usize = 0;
    while (parser.parse() catch |err| {
        std.log.err("Parser Error: {}", .{err});
        if (parser.currentToken()) |last_token| {
            std.log.debug("at: {f}", .{last_token.start});
            const min_line = @max(1, last_token.start.line -| 1);
            const max_line = last_token.end.line +| 1;

            var lines = std.mem.splitScalar(u8, source, '\n');
            var i: usize = 0;
            while (lines.next()) |line| {
                i += 1;
                if (i > max_line) break;
                if (i >= min_line) {
                    if (i >= last_token.start.line and i <= last_token.end.line) {
                        std.log.debug("{}: > {s}", .{ i, line });
                    } else {
                        std.log.debug("{}:   {s}", .{ i, line });
                    }
                }
            }
        }
        return;
    }) |instruction| {
        try instructions.append(A.allocator, instruction);
        std.log.debug("[{}:L{}] {f}", .{
            parser.ip - 1,
            parser.source_map.items[instruction_idx].srcLine(),
            instruction,
        });
        instruction_idx += 1;
    }

    const td = t0.untilNow(init.io, .real);
    std.log.debug("compilation done in {f}.", .{td});

    const source_map = try parser.source_map.toOwnedSlice(A.allocator);
    var vm = try VM.init(instructions.items, parser.labels, source_map);
    runDebugger(init.io, &vm, source_map) catch |err| {
        // _ = vm.run() catch |err| {
        std.log.err("VM Error: {}", .{err});

        const curr_tok = source_map[vm.ip];
        const curr_line = curr_tok.srcLine();
        std.log.debug("at: {}", .{curr_line});
        const min_line = @max(1, curr_line -| 1);
        const max_line = curr_line +| 1;

        var lines = std.mem.splitScalar(u8, source, '\n');
        var i: usize = 0;
        while (lines.next()) |line| {
            i += 1;
            if (i > max_line) break;
            if (i >= min_line) {
                if (i == curr_line) {
                    std.log.debug("{}: > {s}", .{ i, line });
                } else {
                    std.log.debug("{}:   {s}", .{ i, line });
                }
            }
        }

        for (vm.frames.items, 0..) |frame, j| {
            std.log.debug("${}: {f}\n", .{ j, frame });
        }
    };

    // const tokens = try @import("tokenizer.zig").Tokenizer.tokenize(source);
    // std.log.debug("tokens:", .{});
    // for (tokens) |token| std.log.debug("{f}", .{token});

    // const ex = @import("raylib.zig");
    //
    // var labels: std.StringHashMap(usize) = .init(A.allocator);
    // try ex.initLabels(&labels);
    // const vm: VM = try .init(ex.ir, labels);
    // // defer vm.deinit();
    //
    // // const ret_value = try vm.run();
    //
    // try runDebugger(init.io, vm);
    //
    // // std.log.debug("final ret_value: {any}", .{ret_value});

    std.log.debug("arena capacity: {} bytes", .{init.arena.queryCapacity()});
}

fn runDebugger(io: std.Io, vm: *VM, source_map: []const Token) !void {
    var debugger = Debugger.init(vm, source_map);

    var stdin_buffer: [1024]u8 = undefined;

    const stdin_file = std.Io.File.stdin();
    var stdin_file_reader = stdin_file.reader(io, &stdin_buffer);
    const stdin = &stdin_file_reader.interface;

    const stdout_file = std.Io.File.stdout();
    var stdout_file_writer = stdout_file.writer(io, &.{});
    const stdout = &stdout_file_writer.interface;

    const stderr_file = std.Io.File.stderr();
    var stderr_file_writer = stderr_file.writer(io, &.{});
    const stderr = &stderr_file_writer.interface;

    while (true) {
        try debugger.printContext(stdout);
        switch (try debugger.readAndExecuteCommand(stdin, stdout, stderr)) {
            .paused => continue,
            .finished => |s| {
                try stdout.print("Debugger finished with return value: {any}", .{s});
                return;
            },
            .err => {
                try stderr.print("Debugger finished with error.", .{});
                return error.VMError;
            },
        }
    }
}
