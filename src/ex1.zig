const std = @import("std");
const IRInstruction = @import("effect-vm.zig").IRInstruction;

pub const ir: []const IRInstruction = &.{
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
