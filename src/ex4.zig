const std = @import("std");
const IRInstruction = @import("effect-vm.zig").IRInstruction;

pub fn initLabels(labels: *std.StringHashMap(usize)) !void {
    try labels.put("main_try_handle_defer", 8);
    try labels.put("main_defer_effect_handler", 15);
}

pub const ir: []const IRInstruction = &.{
    .init(.pushHandler(0, .label("main_defer_effect_handler"))),
    .init(.jmp(.label("main_try_handle_defer"))),
    .init(.bind("deferred", .ret_reg)),
    .init(.print(.string, .literal("before deffered()"))),
    .init(.callCont(.identifier("deferred"), .void_)),
    .init(.print(.string, .literal("after deffered()"))),
    // main_end:
    .init(.popHandler(0)),
    .init(.ret(.ret_reg)),

    // main_try_handle_defer:
    .init(.perform(0, "defer", .void_)),
    .init(.pushFrame("run_inner")),
    .init(.set(.ip(.ret_ip, .rel(2)))),
    .init(.jmp(.rel(2))),
    .init(.ret(.void_)),

    // run_inner:
    .init(.print(.string, .literal("hello from run_inner"))),
    .init(.ret(.void_)),

    // main_defer_effect_handler:
    // Defer.defer:
    .init(.unwind(.handler, .resume_)),

    // while
    .init(.pushFrame("predicate")),
    .init(.set(.ip(.ret_ip, .rel(2)))),
    .init(.jmp(.value(.identifier("pred")))),
    .init(.jnez(.ret_reg, .rel(5))),
    .init(.pushFrame("while body")),
    .init(.set(.ip(.ret_ip, .rel(2)))),
    .init(.jmp(.value(.identifier("body")))),
    .init(.jmp(.rel(-7))),
    .init(.ret(.void_)),
};
