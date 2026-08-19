pub const ct = @import("comptime.zig");

// // pub fn Expr(comptime T: type) type {
// //     return union(enum) {
// //         literal_: Literal(T),
// //
// //         pub fn literal(t: T) @This() {
// //             return .{ .literal_ = .{ .value = t } };
// //         }
// //
// //         pub fn evaluate(self: @This()) T {
// //             return switch (self) {
// //                 inline else => |s| s.evaluate(),
// //             };
// //         }
// //     };
// // }
//
// // pub fn Literal(comptime T: type) type {
// //     return struct {
// //         value: T,
// //
// //         pub fn evaluate(self: @This()) T {
// //             return self.value;
// //         }
// //     };
// // }
//
// // pub fn Expr2(comptime In: type, comptime Out: type) type {
// //     return union(enum) {
// //         result: Result(Out),
// //         bind: Bind(In, Out),
// //
// //         pub fn evaluate(self: @This()) Out {
// //             return switch (self) {
// //                 inline else => |s| s.evaluate(),
// //             };
// //         }
// //     };
// // }
//
// // fn Bind(comptime In: type, comptime Out: type) type {
// //     return struct {
// //         expr: *const In,
// //         f: *const fn (ElementOf(In)) Expr(Out),
// //
// //         pub fn evaluate(self: @This()) Out {
// //             const v = self.expr.evaluate();
// //             const e = self.f(v);
// //             return e.evaluate();
// //         }
// //     };
// // }
// //
// pub fn Result(comptime T: type) type {
//     return union(enum) {
//         literal_: T,
//         deferred_: *const fn () T,
//
//         pub fn literal(t: T) @This() {
//             return .{ .literal_ = t };
//         }
//
//         pub fn deferred(comptime f: *const fn () T) Result(T) {
//             return .{ .deferred_ = f };
//         }
//
//         // pub fn bind(
//         //     comptime U: type,
//         //     expr: *const Result(U),
//         //     f: *const fn (U) Result(T),
//         // ) Expr(U, T) {
//         //     return .{ .bind = .{ .expr = expr, .f = f } };
//         // }
//
//         pub fn evaluate(self: @This()) T {
//             return switch (self) {
//                 .literal_ => |t| t,
//                 .deferred_ => |d| d(),
//             };
//         }
//     };
// }
//
// fn initRaylib(window_size: Vector2, title: [:0]const u8) void {
//     const x, const y = @as(Vector2Int(i32), @intFromFloat(window_size));
//     rl.initWindow(x, y, title);
//     rl.initAudioDevice();
// }
//
// fn deinitRaylib() void {
//     rl.closeAudioDevice();
//     rl.closeWindow();
// }
//
// pub const Game = struct {
//     p_init: std.process.Init,
//     title: [:0]const u8,
//     window_size: Vector2,
//     reg: ecs.Registry,
//     wants_to_quit: bool = false,
//
//     pub fn init(p_init: std.process.Init, title: [:0]const u8, window_size: Vector2) Game {
//         return .{
//             .p_init = p_init,
//             .title = title,
//             .window_size = window_size,
//             .reg = .init(p_init.gpa),
//         };
//     }
//
//     pub fn deinit(self: *@This()) void {
//         self.reg.deinit();
//         deinitRaylib();
//     }
//
//     pub fn setup(self: *@This()) void {
//         initRaylib(self.window_size, self.title);
//         self.reg.singletons().add(rl.Camera2D{
//             .offset = @bitCast(self.window_size / V2.s(2)),
//             .target = .zero(),
//             .rotation = 0,
//             .zoom = 4,
//         });
//     }
//
//     fn isRunning(self: @This()) bool {
//         if (self.wants_to_quit) return false;
//         if (rl.windowShouldClose()) return false;
//         return true;
//     }
//
//     pub fn run(self: *@This()) void {
//         while (self.isRunning()) {
//             rl.beginDrawing();
//             const camera = self.reg.singletons().getConst(rl.Camera2D);
//             camera.begin();
//             rl.clearBackground(.black);
//             const v = self.view(.{Body}, .{});
//             v.applyFn(self, drawEntity);
//             camera.end();
//             rl.endDrawing();
//         }
//     }
//
//     fn drawEntity(_: *@This(), entity: Entity) void {
//         const body = entity.get(Body);
//         rl.drawRectangleV(@bitCast(body.position), @bitCast(body.size), .white);
//     }
//
//     pub fn create(self: *@This(), init_fields: []const EntityField) Entity {
//         const entity = Entity.create(&self.reg);
//
//         for (init_fields) |field| {
//             entity.set(field);
//         }
//
//         return entity;
//     }
//
//     pub fn single(self: *@This(), id: ecs.Entity) ContextEntity {
//         return .{ .id = id, .reg = &self.reg };
//     }
//
//     pub fn view(self: *@This(), comptime includes: anytype, comptime excludes: anytype) ContextView(includes, excludes) {
//         return .{ .reg = &self.reg };
//     }
// };
//
// pub const Context = struct {
//     ptr: *anyopaque,
//     vtable: *const VTable,
//
//     pub const VTable = struct {
//         apply: *const fn (anyopaque, ContextOperation) void,
//     };
//
//     pub fn apply(self: @This(), op: ContextOperation) void {
//         self.vtable.set(self.ptr, op);
//     }
// };
//
// pub const ContextOperation = union(enum) {
//     set_: EntityField,
//     seq_: []const ContextOperation,
//
//     pub fn set(field: EntityField) @This() {
//         return .{ .set_ = field };
//     }
//
//     pub fn seq(ops: []const ContextOperation) @This() {
//         return .{ .seq_ = ops };
//     }
// };
//
// pub const ContextEntity = struct {
//     id: ecs.Entity,
//     reg: *ecs.Registry,
//
//     fn _apply(ptr: *anyopaque, operation: ContextOperation) void {
//         const self = @as(*@This(), @ptrCast(ptr));
//         self.apply(operation);
//     }
//
//     pub fn apply(self: @This(), operation: ContextOperation) void {
//         const ctx = Entity.init(self.id, self.reg);
//         ctx.apply(operation);
//     }
// };
//
// pub fn ContextView(comptime includes: anytype, comptime excludes: anytype) type {
//     return struct {
//         reg: *ecs.Registry,
//
//         pub fn apply(ptr: *anyopaque, operation: ContextOperation) void {
//             const self = @as(*@This(), @ptrCast(ptr));
//
//             self.applyFn(operation, applySingle);
//         }
//
//         fn applySingle(operation: ContextOperation, entity: Entity) void {
//             entity.apply(operation);
//         }
//
//         fn applyFn(
//             self: @This(),
//             context: anytype,
//             f: *const fn (@TypeOf(context), Entity) void,
//         ) void {
//             var view = self.reg.view(includes, excludes);
//             var it = view.entityIterator();
//
//             while (it.next()) |entity| {
//                 const ctx = Entity.init(entity, self.reg);
//                 f(context, ctx);
//             }
//         }
//     };
// }
//
// pub const deltaTime = Result(f32).deferred(rl.getFrameTime);
// pub const time = Result(f64).deferred(rl.getTime);
