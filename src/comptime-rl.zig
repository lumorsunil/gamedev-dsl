const rl = @import("raylib");
const core = @import("comptime-core.zig");
const selector = @import("selector.zig");

const V2 = selector.V2;
const Vector2 = selector.Vector2;
const WorldVector = selector.WorldVector;

const closured = core.closured;
const lift = core.lift;
const noCtx = core.noCtx;

const Expr = @import("comptime-core.zig").Expr;

// Base

pub fn initWindow(comptime window_size: @Vector(2, i32)) Expr {
    return closured(initWindow_, window_size);
}
pub const time: Expr = lift(rl.getTime);
pub const delta_time: Expr = lift(rl.getFrameTime);
pub const close_window: Expr = lift(rl.closeWindow);
fn initWindow_(_: anytype, comptime window_size: @Vector(2, i32)) void {
    const x, const y = window_size;
    rl.initWindow(x, y, "comptime");
}
pub const window_should_close: Expr = lift(rl.windowShouldClose);

// Draw

pub const begin_drawing: Expr = lift(rl.beginDrawing);
pub const end_drawing: Expr = lift(rl.endDrawing);
pub fn clearBackground(comptime color: rl.Color) Expr {
    return closured(_clearBackground, color);
}
fn _clearBackground(_: anytype, comptime color: rl.Color) void {
    rl.clearBackground(color);
}
pub fn drawRectangleV(
    comptime position: Expr,
    comptime size: Expr,
    comptime color: Expr,
) Expr {
    const impl = struct {
        pub fn compile(comptime ctx: *core.CompilationContext) core.Eval {
            const eval_position = position.compile_(ctx);
            const eval_size = size.compile_(ctx);
            const eval_color = color.compile_(ctx);

            return struct {
                fn evaluate(ctx_: *core.Context) core.Value {
                    const position_ = eval_position(ctx_);
                    const size_ = eval_size(ctx_);
                    const color_ = eval_color(ctx_);

                    rl.drawRectangleV(@bitCast(position_), @bitCast(size_), color_);

                    return .void_;
                }
            }.evaluate;
        }
    };

    return .init(core.compileTypeConst(void), impl.compile);
}

// Input

pub fn isKeyDown(comptime key: rl.KeyboardKey) Expr {
    return closured(_isKeyDown, key);
}
fn _isKeyDown(_: anytype, comptime key: rl.KeyboardKey) bool {
    return rl.isKeyDown(key);
}
