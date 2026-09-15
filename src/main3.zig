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
    // fn printState() {
    //   const state = State.get()
    // }
    //
    // fn run(state_effect: State u64) {
    //   state_effect.set(42)
    //   const result = state_effect.get()
    //   print(result)
    // }
    //
    // fn main() {
    //   var state: u64 = 0
    //
    //   state_effect: State u64 {              // START OF TRY/HANDLER SCOPE
    //     get() {
    //       resume state
    //       print("from get: in the end, state was: " + state)
    //     }
    //     set(v) {
    //       state = v
    //       resume
    //       print("from set: in the end, state was: " + state)
    //     }
    //   }
    //
    //   run(state_effect)
    // }                                        // END OF TRY/HANDLER SCOPE
    //

    var labels: std.StringHashMap(usize) = .init(A.allocator);
    // defer labels.deinit();

    try labels.put("main_try_handle_state", 5);
    try labels.put("main_state_effect_handler", 10);

    const ir: []const IRInstruction = &.{
        .{ .instruction_type = .{ .bind = .{ .identifier = "state", .value = .{ .literal = std.mem.asBytes(&@as(usize, 0)) } } } },
        .{ .instruction_type = .{ .push_handler = .{ .effect_id = 0, .handler_ip = .{ .label = "main_state_effect_handler" } } } },
        .{ .instruction_type = .{ .jmp = .{ .ip = .{ .label = "main_try_handle_state" } } } },
        // main_end:
        .{ .instruction_type = .{ .pop_handler = .{ .effect_id = 0 } } },
        .{ .instruction_type = .ret },

        // main_try_handle_state:
        .{ .instruction_type = .{ .perform = .{ .effect_id = 0, .operation = "set", .arg_val = .{ .literal = std.mem.asBytes(&@as(usize, 42)) } } } },
        .{ .instruction_type = .{ .perform = .{ .effect_id = 0, .operation = "get", .arg_val = .void_ } } },
        .{ .instruction_type = .{ .bind = .{ .identifier = "result", .value = .payload } } },
        .{ .instruction_type = .{ .print = .{ .value = .{ .identifier = "result" } } } },
        .{ .instruction_type = .ret },

        // main_state_effect_handler:
        .{ .instruction_type = .{ .jeq = .{ .lhs = .operation, .rhs = .{ .literal = "set" }, .ip = .{ .rel = 2 } } } },
        .{ .instruction_type = .{ .jeq = .{ .lhs = .operation, .rhs = .{ .literal = "get" }, .ip = .{ .rel = 5 } } } },
        // State.set
        .{ .instruction_type = .{ .bind = .{ .identifier = "state", .value = .payload } } },
        .{ .instruction_type = .{ .resume_ = .{ .value = .void_ } } },
        .{ .instruction_type = .{ .print = .{ .value = .{ .literal = "set after resume" } } } },
        .{ .instruction_type = .ret },
        // State.get
        .{ .instruction_type = .{ .resume_ = .{ .value = .{ .identifier = "state" } } } },
        .{ .instruction_type = .{ .print = .{ .value = .{ .literal = "get after resume" } } } },
        .{ .instruction_type = .ret },
        // State.utils
        // ...
    };
    var vm: VM = try .init(ir, labels);
    // defer vm.deinit();

    try vm.run();
}
