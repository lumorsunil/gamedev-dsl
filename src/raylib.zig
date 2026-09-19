const std = @import("std");
const IRInstruction = @import("effect-vm.zig").IRInstruction;

pub fn initLabels(labels: *std.StringHashMap(usize)) !void {
    try labels.put("finally_handler_scope", 6);
    try labels.put("while_pred", 26);
    try labels.put("while_body", 30);
    try labels.put("while", 48);
    try labels.put("finally_handler", 55);
    try labels.put("main_finally_f", 60);
}

const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn rgb(r: u8, g: u8, b: u8) @This() {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }
};

pub const ir: []const IRInstruction = &.{
    // main:
    .init(.pushFrame("main")),
    .init(.set(.ip(.ret_ip, .abs(std.math.maxInt(usize))))),

    // finally handler
    .init(.pushHandler(0, .label("finally_handler"))),
    .init(.jmp(.label("finally_handler_scope"))),

    // main_end:
    .init(.popHandler(0)),
    .init(.ret(.void_)),

    // finally_handler_scope:
    // init raylib
    .init(.callExternFn("initWindow", &.{
        .literal(std.mem.asBytes(&@as(i32, 800))),
        .literal(std.mem.asBytes(&@as(i32, 600))),
        .literal("EffectVM Raylib"),
    })),
    .init(.callExternFn("setWindowPosition", &.{
        .literal(std.mem.asBytes(&@as(i32, 24))),
        .literal(std.mem.asBytes(&@as(i32, 24))),
    })),
    .init(.pushFrame("finally")),
    .init(.bind("f", .void_)),
    .init(.set(.f("f", .function(.label("main_finally_f"))))),
    .init(.perform(0, "finally")),

    // call while
    .init(.bind("x", .literal(std.mem.asBytes(&@as(i32, 0))))),
    .init(.bind("y", .literal(std.mem.asBytes(&@as(i32, 0))))),
    .init(.pushFrame("while")),

    // pred lambda
    .init(.bind("pred", .void_)),
    .init(.set(.f("pred", .function(.label("while_pred"))))),

    // body lambda
    .init(.bind("body_capture", .void_)),
    .init(.pushFrame("body_capture")),
    .init(.bind("x", .pointer(.stack(.rel(-2), "x")))),
    .init(.bind("y", .pointer(.stack(.rel(-2), "y")))),
    .init(.set(.popFrame("body_capture"))),
    .init(.bind("body", .void_)),
    .init(.set(.f("body", .continuation(
        .identifier("body_capture"),
        .label("while_body"),
    )))),

    .init(.set(.ip(.ret_ip, .rel(2)))),
    .init(.jmp(.label("while"))),

    // while_pred:
    .init(.callExternFn("windowShouldClose", &.{})),
    .init(.jz(.ret_reg, .rel(2))),
    .init(.ret(.literal(&.{0}))),
    .init(.ret(.literal(&.{1}))),

    // while_body:
    .init(.callExternFn("isKeyDown", &.{.literal(std.mem.asBytes(&@as(i32, 65)))})),
    .init(.jz(.ret_reg, .rel(2))),
    .init(.dec(.deref(.identifier("x")))),
    .init(.callExternFn("isKeyDown", &.{.literal(std.mem.asBytes(&@as(i32, 68)))})),
    .init(.jz(.ret_reg, .rel(2))),
    .init(.inc(.deref(.identifier("x")))),
    .init(.callExternFn("isKeyDown", &.{.literal(std.mem.asBytes(&@as(i32, 87)))})),
    .init(.jz(.ret_reg, .rel(2))),
    .init(.dec(.deref(.identifier("y")))),
    .init(.callExternFn("isKeyDown", &.{.literal(std.mem.asBytes(&@as(i32, 83)))})),
    .init(.jz(.ret_reg, .rel(2))),
    .init(.inc(.deref(.identifier("y")))),
    .init(.callExternFn("beginDrawing", &.{})),
    .init(.callExternFn("clearBackground", &.{.literal(std.mem.asBytes(&Color.rgb(77, 88, 99)))})),
    .init(.callExternFn("drawRectangle", &.{
        .deref(&.identifier("x")),
        .deref(&.identifier("y")),
        .literal(std.mem.asBytes(&@as(i32, 100))),
        .literal(std.mem.asBytes(&@as(i32, 100))),
        .literal(std.mem.asBytes(&Color.rgb(255, 255, 255))),
    })),
    .init(.callExternFn("drawFPS", &.{
        .literal(std.mem.asBytes(&@as(i32, 5))),
        .literal(std.mem.asBytes(&@as(i32, 5))),
    })),
    .init(.callExternFn("endDrawing", &.{})),
    .init(.ret(.void_)),

    // while:
    .init(.pushFrame("pred")),
    .init(.set(.ip(.ret_ip, .rel(2)))),
    .init(.jmp(.value(.identifier("pred")))),
    .init(.jz(.ret_reg, .rel(3))),
    .init(.callCont(.identifier("body"), .void_)),
    .init(.jmp(.rel(-5))),
    .init(.ret(.void_)),

    // finally_handler:
    .init(.resume_(.void_)),
    .init(.pushFrame("f")),
    .init(.set(.ip(.ret_ip, .rel(2)))),
    .init(.jmp(.value(.identifier("f")))),
    .init(.ret(.void_)),

    // main_finally_f:
    .init(.callExternFn("closeWindow", &.{})),
    .init(.ret(.void_)),
};
