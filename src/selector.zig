const std = @import("std");
const ecs = @import("ecs");

const core = @import("comptime-core.zig");

const map = core.map;

const Expr = @import("comptime-core.zig").Expr;

pub const V2 = struct {
    pub fn s(scalar: f32) Vector2 {
        return @splat(scalar);
    }
};

pub const Vector2 = @Vector(2, f32);
fn Vector2Int(comptime T: type) type {
    return @Vector(2, T);
}
pub const WorldVector = Vector2;

pub const Player = struct {};

pub const Body = struct {
    position: WorldVector = .{ 0, 0 },
    size: WorldVector = .{ 16, 16 },
};

pub const Tag = union(enum) {
    body: Body,
};

pub const EntityFieldTag = enum {
    player_,
    position_,
    size_,
};

pub const EntityField = union(EntityFieldTag) {
    player_: Expr,
    position_: Expr,
    size_: Expr,

    pub fn player(is_player: Expr) @This() {
        return .{ .player_ = is_player };
    }

    pub fn position(new_position: Expr) @This() {
        return .{ .position_ = new_position };
    }

    pub fn size(new_size: Expr) @This() {
        return .{ .size_ = new_size };
    }

    pub fn compile(comptime self: @This(), comptime ctx: *core.CompilationContext) EntityFieldEval {
        return switch (comptime self) {
            inline else => |s, t| @unionInit(EntityFieldEval, @tagName(t), s.compile_(ctx)),
        };
    }
};

fn EntityFieldPayload(comptime field: EntityFieldTag) type {
    return switch (field) {
        .player_ => bool,
        .position_ => WorldVector,
        .size_ => WorldVector,
    };
}

const EntityFieldEval = union(EntityFieldTag) {
    player_: core.Eval,
    position_: core.Eval,
    size_: core.Eval,
};

pub const Entity = struct {
    id: ecs.Entity,
    reg: *ecs.Registry,

    pub fn init(id: ecs.Entity, reg: *ecs.Registry) @This() {
        return .{ .id = id, .reg = reg };
    }

    pub fn create(reg: *ecs.Registry) @This() {
        return .init(reg.create(), reg);
    }

    pub fn add(self: @This(), component: anytype) void {
        return self.reg.add(self.id, component);
    }

    pub fn get(self: @This(), comptime T: type) *T {
        return self.reg.get(T, self.id);
    }

    pub fn has(self: @This(), comptime T: type) bool {
        return self.reg.has(T, self.id);
    }

    fn getOrAdd(self: @This(), comptime T: type) *T {
        if (self.reg.has(T, self.id)) {
            return self.reg.get(T, self.id);
        }
        self.reg.add(self.id, T{});
        return self.reg.get(T, self.id);
    }

    pub fn addOrReplace(self: @This(), component: anytype) void {
        self.reg.addOrReplace(self.id, component);
    }

    pub fn removeIfExists(self: @This(), comptime T: type) void {
        self.reg.removeIfExists(T, self.id);
    }

    pub fn set(self: @This(), ctx: *core.Context, field: EntityFieldEval) void {
        switch (field) {
            .player_ => |eval| {
                if (eval(ctx)) {
                    self.addOrReplace(Player{});
                } else {
                    self.removeIfExists(Player);
                }
            },
            .position_ => |eval| {
                const body = self.getOrAdd(Body);
                body.position = eval(ctx);
            },
            .size_ => |eval| {
                const body = self.getOrAdd(Body);
                body.size = eval(ctx);
            },
        }
    }

    pub fn apply(self: @This(), ctx: *core.Context, operation: SelectorOperation) void {
        switch (operation) {
            .set_ => |s| self.set(ctx, s),
            .seq_ => |s| for (s) |op| self.apply(ctx, op),
            .apply_ => |s| s(self),
        }
    }

    pub fn getField(
        self: @This(),
        comptime field: EntityFieldTag,
    ) EntityFieldPayload(field) {
        return switch (field) {
            .player_ => self.has(Player),
            .position_ => {
                const body = self.getOrAdd(Body);
                return body.position;
            },
            .size_ => {
                const body = self.getOrAdd(Body);
                return body.size;
            },
        };
    }
};

pub const Selector = union(enum) {
    create,
    last_created: SelectorLastCreated,
    single_: SelectorSingle,
    view_: type,

    pub fn lastCreated() @This() {
        return .{ .last_created = .init() };
    }

    pub fn single(comptime component: type) @This() {
        return .{ .single_ = .init(component) };
    }

    pub fn view(comptime includes: anytype, comptime excludes: anytype) @This() {
        return .{ .view_ = SelectorView(includes, excludes) };
    }

    pub fn apply(self: @This(), ctx: *core.Context, op: SelectorOperation) void {
        switch (self) {
            inline else => |s| s.apply(ctx, op),
        }
    }

    pub fn get(
        self: @This(),
        ctx: *core.Context,
        comptime field: EntityFieldTag,
    ) EntityFieldPayload(field) {
        return switch (self) {
            inline else => |s| s.get(ctx, field),
        };
    }
};

pub const SelectorOperation = union(enum) {
    set_: EntityFieldEval,
    seq_: []const SelectorOperation,
    apply_: *const fn (Entity) void,

    pub fn set(field: EntityFieldEval) @This() {
        return .{ .set_ = field };
    }

    pub fn seq(ops: []const SelectorOperation) @This() {
        return .{ .seq_ = ops };
    }

    pub fn apply(f: *const fn (Entity) void) @This() {
        return .{ .apply_ = f };
    }
};

pub const SelectorEntity = struct {
    id: ecs.Entity,
    reg: *ecs.Registry,

    pub fn init(ctx: *core.Context, id: ecs.Entity) @This() {
        return .{ .id = id, .reg = ctx.reg };
    }

    fn _apply(ptr: *anyopaque, operation: SelectorOperation) void {
        const self = @as(*@This(), @ptrCast(ptr));
        self.apply(operation);
    }

    pub fn apply(self: @This(), operation: SelectorOperation) void {
        const ctx = Entity.init(self.id, self.reg);
        ctx.apply(operation);
    }
};

pub const SelectorLastCreated = struct {
    pub fn init() @This() {
        return .{};
    }

    fn _apply(ptr: *anyopaque, ctx: *core.Context, operation: SelectorOperation) void {
        const self = @as(*@This(), @ptrCast(ptr));
        self.apply(ctx, operation);
    }

    pub fn apply(_: @This(), ctx: *core.Context, operation: SelectorOperation) void {
        const id = ctx.last_created orelse return;
        const entity = Entity.init(id, &ctx.reg);
        entity.apply(ctx, operation);
    }

    pub fn get(
        _: @This(),
        ctx: *core.Context,
        comptime field: EntityFieldTag,
    ) EntityFieldPayload(field) {
        const id = ctx.last_created orelse return;
        const entity = Entity.init(id, &ctx.reg);
        entity.get(ctx, field);
    }
};

pub const SelectorSingle = struct {
    component: type,

    pub fn init(component: type) @This() {
        return .{ .component = component };
    }

    fn _apply(ptr: *anyopaque, ctx: *core.Context, operation: SelectorOperation) void {
        const self = @as(*@This(), @ptrCast(ptr));
        self.apply(ctx, operation);
    }

    fn getEntity(self: @This(), ctx: *core.Context) Entity {
        const id = ctx.reg.data(self.component)[0];
        return .init(id, &ctx.reg);
    }

    pub fn apply(self: @This(), ctx: *core.Context, operation: SelectorOperation) void {
        const entity = self.getEntity(ctx);
        entity.apply(ctx, operation);
    }

    pub fn get(
        self: @This(),
        ctx: *core.Context,
        comptime field: EntityFieldTag,
    ) EntityFieldPayload(field) {
        const entity = self.getEntity(ctx);
        return entity.getField(field);
    }
};

pub fn SelectorView(comptime includes: anytype, comptime excludes: anytype) type {
    return struct {
        pub fn apply(ctx: *core.Context, operation: SelectorOperation) void {
            var view = ctx.reg.view(includes, excludes);
            var it = view.entityIterator();

            while (it.next()) |id| {
                const entity = Entity.init(id, &ctx.reg);
                entity.apply(ctx, operation);
            }
        }
    };
}

pub fn set(comptime field: EntityField) Expr {
    const impl = struct {
        pub fn compile(comptime ctx: *core.CompilationContext) core.Eval {
            const selector = ctx.selector orelse return core.noop;
            const eval_field = field.compile(ctx);

            return struct {
                fn evaluate(ctx_: *core.Context) core.Value {
                    selector.apply(ctx_, .set(eval_field));
                    return .void_;
                }
            }.evaluate;
        }
    };

    return .init(core.compileTypeConst(void), impl.compile);
}

pub fn get(comptime field: EntityFieldTag) Expr {
    const impl = struct {
        pub fn compile(comptime ctx: *core.CompilationContext) core.Eval {
            const selector = ctx.selector orelse return core.noop;

            return struct {
                fn evaluate(ctx_: *core.Context) EntityFieldPayload(field) {
                    return selector.get(ctx_, field);
                }
            }.evaluate;
        }
    };

    return .init(core.compileTypeConst(EntityFieldPayload(field)), impl.compile);
}

pub fn forEachEntity(comptime f: *const fn (entity: Entity) void) Expr(void) {
    return .init(struct {
        pub fn compile(comptime ctx: *core.CompilationContext) core.Eval(void) {
            const selector = ctx.selector orelse return core.noop;

            return struct {
                fn evaluate(ctx_: *core.Context) void {
                    selector.apply(ctx_, .apply(f));
                }
            }.evaluate;
        }
    }.compile);
}
