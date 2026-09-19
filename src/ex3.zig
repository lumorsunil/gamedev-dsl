const std = @import("std");
const IRInstruction = @import("effect-vm.zig").IRInstruction;

pub fn initLabels(labels: *std.StringHashMap(usize)) !void {
    try labels.put("main_try_handle_exception", 5);
    try labels.put("main_try_handle_state", 9);
    try labels.put("main_exception_effect_handler", 18);
    try labels.put("main_state_effect_handler", 20);
}

pub const ir: []const IRInstruction = &.{
    .{ .instruction_type = .{ .bind = .{ .identifier = "state", .value = .literal(std.mem.asBytes(&@as(usize, 0))) } } },
    .{ .instruction_type = .{ .push_handler = .{ .effect_id = 1, .handler_ip = .{ .label = "main_exception_effect_handler" } } } },
    .{ .instruction_type = .{ .jmp = .{ .ip = .{ .label = "main_try_handle_exception" } } } },
    // main_end:
    .{ .instruction_type = .{ .pop_handler = .{ .effect_id = 1 } } },
    .{ .instruction_type = .ret(.ret_reg) },

    // main_try_handle_exception
    .{ .instruction_type = .{ .push_handler = .{ .effect_id = 0, .handler_ip = .{ .label = "main_state_effect_handler" } } } },
    .{ .instruction_type = .{ .jmp = .{ .ip = .{ .label = "main_try_handle_state" } } } },
    // main_try_handle_exception_end:
    .{ .instruction_type = .{ .pop_handler = .{ .effect_id = 0 } } },
    .{ .instruction_type = .ret(.ret_reg) },

    // main_try_handle_state:
    .{ .instruction_type = .perform_(0, "set", .literal(std.mem.asBytes(&@as(usize, 42)))) },
    .{ .instruction_type = .perform_(0, "get", .void_) },
    .{ .instruction_type = .{ .bind = .{ .identifier = "result", .value = .payload } } },
    .{ .instruction_type = .{ .print_ = .init(.number, .identifier("result")) } },
    .{ .instruction_type = .perform_(0, "set", .literal(std.mem.asBytes(&@as(usize, 43)))) },
    .{ .instruction_type = .perform_(0, "get", .void_) },
    .{ .instruction_type = .{ .bind = .{ .identifier = "result2", .value = .payload } } },
    .{ .instruction_type = .{ .print_ = .init(.number, .identifier("result2")) } },
    .{ .instruction_type = .ret(.literal(std.mem.asBytes(&@as(usize, 1)))) },

    // main_exception_effect_handler:
    // Exception.throw:
    .{ .instruction_type = .{ .print_ = .init(.string, .literal("exception was thrown")) } },
    .{ .instruction_type = .unwind(.identifier("state")) },
    // main_state_effect_handler:
    .{ .instruction_type = .{ .jeq = .{ .lhs = .operation, .rhs = .literal("set"), .ip = .{ .rel = 2 } } } },
    .{ .instruction_type = .{ .jeq = .{ .lhs = .operation, .rhs = .literal("get"), .ip = .{ .rel = 6 } } } },
    // State.set
    .{ .instruction_type = .{ .bind = .{ .identifier = "state", .value = .payload } } },
    .{ .instruction_type = .{ .resume_ = .{} } },
    .{ .instruction_type = .{ .bind = .{ .identifier = "result", .value = .ret_reg } } },
    .{ .instruction_type = .{ .print_ = .init(.string, .literal("set after resume")) } },
    .{ .instruction_type = .ret(.identifier("result")) },
    // State.get
    .{ .instruction_type = .{ .jneq = .{ .lhs = .identifier("state"), .rhs = .literal(std.mem.asBytes(&@as(usize, 43))), .ip = .{ .rel = 3 } } } },
    .{ .instruction_type = .perform(1, "throw", .void_) },
    .{ .instruction_type = .ret(.identifier("state")) },
    .{ .instruction_type = .{ .resume_ = .{ .value = .identifier("state") } } },
    .{ .instruction_type = .ret(.ret_reg) },
    // State.utils
    // ...
};
