const std = @import("std");
const VM = @import("effect-vm.zig").VM;
const IRInstruction = @import("effect-vm.zig").IRInstruction;
const InstructionPointer = @import("effect-vm.zig").InstructionPointer;
const A = @import("allocator.zig");

pub fn main(init: std.process.Init) !void {
    A.allocator = init.arena.allocator();

    //
    // effect State a {
    //   get() a
    //   set(new_state: a) void
    // }
    //
    // fn main() {
    //   var state: u64 = 0
    //
    //   state_effect: State u64 {              // START OF TRY/HANDLER SCOPE
    //     get() {
    //       print("get enter")
    //       if state == 43 return
    //       resume state
    //       print("get after resume:")
    //       print(state)
    //     }
    //     set(v) {
    //       print("set enter")
    //       state = v
    //       resume
    //       print("calling second resume")
    //       state = v + 1
    //       resume
    //       print("set after resume")
    //     }
    //   }
    //
    //   state_effect.set(42)
    //   const result = state_effect.get()
    //   print(result)
    // }                                        // END OF TRY/HANDLER SCOPE
    //

    var labels: std.StringHashMap(usize) = .init(A.allocator);
    // defer labels.deinit();

    try labels.put("main_try_handle_state", 5);
    try labels.put("main_state_effect_handler", 10);

    const ir: []const IRInstruction = &.{
        .{ .instruction_type = .{ .bind = .{ .identifier = "state", .value = .literal(std.mem.asBytes(&@as(usize, 0))) } } },
        .{ .instruction_type = .{ .push_handler = .{ .effect_id = 0, .handler_ip = .{ .label = "main_state_effect_handler" } } } },
        .{ .instruction_type = .{ .jmp = .{ .ip = .{ .label = "main_try_handle_state" } } } },
        // main_end:
        .{ .instruction_type = .{ .pop_handler = .{ .effect_id = 0 } } },
        .{ .instruction_type = .ret },

        // main_try_handle_state:
        .{ .instruction_type = .{ .perform = .{ .effect_id = 0, .operation = "set", .arg_val = .literal(std.mem.asBytes(&@as(usize, 42))) } } },
        .{ .instruction_type = .{ .perform = .{ .effect_id = 0, .operation = "get", .arg_val = .void_ } } },
        .{ .instruction_type = .{ .bind = .{ .identifier = "result", .value = .payload } } },
        .{ .instruction_type = .{ .print = .init(.number, .identifier("result")) } },
        .{ .instruction_type = .ret },

        // main_state_effect_handler:
        .{ .instruction_type = .{ .jeq = .{ .lhs = .operation, .rhs = .literal("set"), .ip = .{ .rel = 2 } } } },
        .{ .instruction_type = .{ .jeq = .{ .lhs = .operation, .rhs = .literal("get"), .ip = .{ .rel = 9 } } } },
        // State.set
        .{ .instruction_type = .{ .print = .init(.string, .literal("set enter")) } },
        .{ .instruction_type = .{ .bind = .{ .identifier = "state", .value = .payload } } },
        .{ .instruction_type = .{ .resume_ = .{ .value = .void_ } } },
        .{ .instruction_type = .{ .print = .init(.string, .literal("calling second resume")) } },
        .{ .instruction_type = .{ .bind = .{ .identifier = "state", .value = .literal(std.mem.asBytes(&@as(usize, 43))) } } },
        .{ .instruction_type = .{ .resume_ = .{ .value = .void_ } } },
        .{ .instruction_type = .{ .print = .init(.string, .literal("set after resume")) } },
        .{ .instruction_type = .ret },
        // State.get
        .{ .instruction_type = .{ .print = .init(.string, .literal("get enter")) } },
        .{ .instruction_type = .{ .jeq = .{ .lhs = .identifier("state"), .rhs = .literal(std.mem.asBytes(&@as(usize, 43))), .ip = .{ .rel = 4 } } } },
        .{ .instruction_type = .{ .resume_ = .{ .value = .identifier("state") } } },
        .{ .instruction_type = .{ .print = .init(.string, .literal("get after resume:")) } },
        .{ .instruction_type = .{ .print = .init(.any, .identifier("state")) } },
        .{ .instruction_type = .ret },
        // State.utils
        // ...
    };
    var vm: VM = try .init(ir, labels);
    // defer vm.deinit();

    try vm.run();
}
