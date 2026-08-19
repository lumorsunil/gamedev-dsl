const std = @import("std");
const Allocator = std.mem.Allocator;
const ecs = @import("ecs");
const selector = @import("selector.zig");

const core = @This();

pub const Eval = *const fn (*Context) Value;

pub const noop: Eval =
    struct {
        pub fn evaluate(_: *Context) void {}
    }.evaluate;

pub const ComptimeScope = struct {
    keys: []const K = &.{},
    values: []const V = &.{},

    pub const K = []const u8;
    pub const V = type;

    pub const empty = ComptimeScope{};

    pub fn put(self: *@This(), key: K, value: V) void {
        if (self.getIndex(key)) |i| {
            self.values[i] = value;
        }

        const key_item: []const K = &.{key};
        self.keys = self.keys ++ key_item;
        const value_item: []const V = &.{value};
        self.values = self.values ++ value_item;
    }

    pub fn getIndex(self: @This(), key: K) ?usize {
        for (self.keys, 0..) |k, i| if (std.mem.eql(u8, k, key)) return i;
        return null;
    }

    pub fn get(self: *@This(), key: K) ?V {
        if (self.getIndex(key)) |i| {
            return self.values[i];
        }

        return null;
    }
};

pub const CompilationContext = struct {
    selector: ?selector.Selector = null,
    scope: ComptimeScope = .empty,
};

pub fn compileTypeConst(comptime T: type) *const fn (comptime ctx: *CompilationContext) type {
    return struct {
        pub fn compileType(comptime _: *CompilationContext) type {
            return T;
        }
    }.compileType;
}

pub fn compileConst(comptime value: anytype) *const fn (comptime ctx: *CompilationContext) Eval {
    return struct {
        pub fn compile_(comptime _: *CompilationContext) Eval {
            return struct {
                pub fn evaluate(_: *Context) Value {
                    return .init(value);
                }
            }.evaluate;
        }
    }.compile_;
}

pub const RuntimeScope = struct {
    map: std.StringHashMap(V),

    pub const K = []const u8;
    pub const V = Value;

    pub fn init(allocator: Allocator) @This() {
        return .{ .map = .init(allocator) };
    }

    pub fn deinit(self: *@This()) void {
        self.map.deinit();
    }

    pub fn put(self: *@This(), key: K, value: V) void {
        self.map.put(key, value) catch unreachable;
    }

    pub fn get(self: *@This(), key: K) ?V {
        return self.map.get(key);
    }
};

pub const Context = struct {
    io: std.Io,
    reg: ecs.Registry,
    scope: RuntimeScope,
    last_created: ?ecs.Entity = null,

    pub fn init(init_: std.process.Init) @This() {
        return .{
            .io = init_.io,
            .reg = .init(init_.gpa),
            .scope = .init(init_.gpa),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.reg.deinit();
        self.scope.deinit();
    }
};

pub fn compile(
    comptime expr: anytype,
) Eval {
    var ctx = CompilationContext{};
    return expr.compile(&ctx);
}

pub fn evaluate(
    comptime eval: anytype,
    ctx: *Context,
) ReturnType(@TypeOf(eval)) {
    return eval(ctx);
}

fn Param(comptime i: usize, comptime T: type) type {
    return switch (@typeInfo(T)) {
        .@"fn" => |ti| ti.params[i].type orelse void,
        .pointer => |p| ReturnType(p.child),
        else => unreachable,
    };
}

fn ReturnType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .@"fn" => |ti| ti.return_type orelse void,
        .pointer => |p| ReturnType(p.child),
        else => @compileError(std.fmt.comptimePrint("Invalid type {s}", .{@typeName(T)})),
    };
}

pub const Value = struct {
    value_: type,

    pub const void_ = Value.init({});

    pub fn init(value_: anytype) @This() {
        return .{ .value_ = struct {
            pub const value = value_;
        } };
    }

    pub fn get(self: @This()) anyopaque {
        return self.value_.value;
    }
};

pub const Expr = struct {
    compile_type_: *const fn (comptime ctx: *CompilationContext) type,
    compile_: *const fn (comptime ctx: *CompilationContext) Eval,

    pub fn init(
        compile_type_: *const fn (comptime ctx: *CompilationContext) type,
        compile_: *const fn (comptime ctx: *CompilationContext) Eval,
    ) @This() {
        return .{
            .compile_type_ = compile_type_,
            .compile_ = compile_,
        };
    }

    pub fn compileType(self: @This(), comptime ctx: *CompilationContext) type {
        return self.compile_type_(ctx);
    }

    pub fn compile(self: @This(), comptime ctx: *CompilationContext) Eval {
        return self.compile_(ctx);
    }

    pub fn literal(value: anytype) @This() {
        return core.literal(value);
    }

    pub fn identifier(comptime identifier_: []const u8) @This() {
        return core.identifier(identifier_);
    }
};

pub fn literal(comptime value: anytype) Expr {
    return .init(compileTypeConst(@TypeOf(value)), compileConst(value));
}

pub fn identifier(comptime identifier_: []const u8) Expr {
    const impl = struct {
        fn compileType(comptime ctx: *CompilationContext) type {
            return ctx.scope.get(identifier_) orelse @compileError("identifier " ++ identifier_ ++ " not found in scope");
        }

        fn compile(comptime ctx: *CompilationContext) Eval {
            if (ctx.scope.getIndex(identifier_) == null) {
                @compileError("identifier " ++ identifier_ ++ " not found in scope");
            }

            return struct {
                fn evaluate(ctx_: *Context) Value {
                    return .init(ctx_.scope.get(identifier_)) orelse @panic("compiler bug: couldn't find value of identifier " ++ identifier_);
                }
            }.evaluate;
        }
    };

    return .init(impl.compileType, impl.compile);
}

pub fn Lift(comptime producer: anytype) Expr {
    const impl = struct {
        pub fn compile(comptime _: *CompilationContext) Eval {
            return struct {
                pub fn evaluate(_: *Context) Value {
                    return .init(producer());
                }
            }.evaluate;
        }
    };

    return .init(compileTypeConst(ReturnType(@TypeOf(producer))), impl.compile);
}

pub fn lift(comptime f: anytype) Expr {
    return Lift(f);
}

pub fn Closured(
    comptime closure: anytype,
    comptime producer: anytype,
) Expr {
    const impl = struct {
        pub fn compileType(comptime _: *CompilationContext) type {
            return ReturnType(producer);
        }

        pub fn compile(comptime _: *CompilationContext) Eval {
            return struct {
                pub fn evaluate(ctx: *Context) Value {
                    return .init(producer(ctx, closure));
                }
            }.evaluate;
        }
    };

    return .init(impl.compileType, impl.compile);
}

pub fn closured(comptime f: anytype, comptime closure: anytype) Expr {
    return Closured(closure, f);
}

pub fn Closured2(
    comptime T: type,
    comptime C: type,
    comptime C2: type,
) fn (comptime closure: C, comptime closure2: C2, comptime producer: *const fn (*Context, C, C2) T) Expr(T) {
    return struct {
        pub fn impl(comptime closure: C, comptime closure2: C2, comptime producer: *const fn (*Context, C, C2) T) Expr(T) {
            return struct {
                pub fn evaluate(ctx: *Context) T {
                    return producer(ctx, closure, closure2);
                }
            }.evaluate;
        }
    }.impl;
}

pub fn closured2(comptime f: anytype, comptime closure: anytype, comptime closure2: anytype) Expr(ReturnType(@TypeOf(f))) {
    return Closured2(ReturnType(@TypeOf(f)), @TypeOf(closure), @TypeOf(closure2))(closure, closure2, f);
}

pub fn map(comptime in: anytype, comptime f: anytype) Expr {
    const impl = struct {
        fn compile(comptime ctx: *CompilationContext) Eval {
            const e_in = in.compile_(ctx);

            return struct {
                pub fn evaluate_(ctx_: *Context) Value {
                    const i = evaluate(e_in, ctx_);
                    return .init(f(i));
                }
            }.evaluate_;
        }
    };

    return .init(compileTypeConst(ReturnType(@TypeOf(f))), impl.compile);
}

pub fn bind(comptime in: anytype, comptime f: anytype) Expr {
    const impl = struct {
        pub fn compileType(comptime ctx: *CompilationContext) type {
            const eval_in = in.compile_(ctx);
            const expr_out = f(eval_in);
            return expr_out.compileType(ctx);
        }

        pub fn compile(comptime ctx: *CompilationContext) Eval {
            const eval_in = in.compile(ctx);
            const expr_out = f(eval_in);
            return expr_out.compile(ctx);
        }
    };

    return .init(impl.compileType, impl.compile);
}

pub fn noCtx(comptime f: anytype) *const fn (*Context) ReturnType(@TypeOf(f)) {
    return struct {
        pub fn impl(_: *Context) ReturnType(@TypeOf(f)) {
            return f();
        }
    }.impl;
}

fn void_(comptime expr: anytype) Expr {
    const impl = struct {
        pub fn compile(comptime ctx: *CompilationContext) Eval {
            const eval = expr.compile_(ctx);
            return struct {
                fn evaluate(ctx_: *Context) Value {
                    _ = eval(ctx_);
                    return .void_;
                }
            }.evaluate;
        }
    };

    return .init(compileTypeConst(void), impl.compile);
}

pub fn seq(comptime s: anytype) Expr {
    const impl = struct {
        pub fn compile(comptime ctx: *CompilationContext) Eval {
            var evals: []const Eval = &.{};
            inline for (s) |expr| {
                const item: []const Eval = &.{void_(expr).compile_(ctx)};
                evals = evals ++ item;
            }
            const evals_ = evals;

            return struct {
                fn evaluate(ctx_: *Context) Value {
                    inline for (evals_) |eval| {
                        eval(ctx_);
                    }
                    return .void_;
                }
            }.evaluate;
        }
    };

    return .init(compileTypeConst(void), impl.compile);
}

fn EvalSeq(comptime S: type) *const fn (*Context, comptime s: S) void {
    return struct {
        fn evaluateSeq(ctx: *Context, comptime s: S) void {
            inline for (s) |e| {
                evaluate(e, ctx);
            }
        }
    }.evaluateSeq;
}

pub fn whil(comptime b_expr: Expr, comptime expr: anytype) Expr {
    const impl = struct {
        pub fn compile(comptime ctx: *CompilationContext) Eval {
            const b_eval = b_expr.compile_(ctx);
            const eval = expr.compile_(ctx);

            return struct {
                fn evaluate_(ctx_: *Context) Value {
                    while (true) {
                        const b = evaluate(b_eval, ctx_);
                        if (!b) return;

                        evaluate(eval, ctx_);
                    }

                    return .void_;
                }
            }.evaluate_;
        }
    };

    return .init(compileTypeConst(void), impl.compile);
}

pub fn until(comptime b_expr: Expr, comptime expr: anytype) Expr {
    return whil(not(b_expr), expr);
}

pub fn not(comptime b_expr: Expr) Expr {
    return map(b_expr, not_);
}

fn not_(b: bool) bool {
    return !b;
}

fn ExprArgsToEvalArgs(comptime ExprArgs: type) type {
    var field_types: []const type = &.{};

    for (std.meta.fields(ExprArgs)) |_| {
        const item: []const type = &.{Eval};
        field_types = field_types ++ item;
    }

    return @Tuple(field_types);
}

fn EvalArgsToArgs(comptime EvalArgs: type) type {
    var field_types: []const type = &.{};

    for (std.meta.fields(EvalArgs)) |field| {
        const item: []const type = &.{ReturnType(field.type)};
        field_types = field_types ++ item;
    }

    return @Tuple(field_types);
}

fn exprArgsToEvalArgs(
    comptime ctx: *CompilationContext,
    comptime expr_args: anytype,
) ExprArgsToEvalArgs(@TypeOf(expr_args)) {
    var args: ExprArgsToEvalArgs(@TypeOf(expr_args)) = undefined;

    inline for (std.meta.fields(@TypeOf(expr_args))) |field| {
        @field(args, field.name) = @field(expr_args, field.name).compile_(ctx);
    }

    return args;
}

fn evalArgsToArgs(ctx: *Context, comptime eval_args: anytype) EvalArgsToArgs(@TypeOf(eval_args)) {
    var args: EvalArgsToArgs(@TypeOf(eval_args)) = undefined;

    inline for (std.meta.fields(@TypeOf(eval_args))) |field| {
        @field(args, field.name) = evaluate(@field(eval_args, field.name), ctx);
    }

    return args;
}

pub fn log(comptime fmt: []const u8, comptime expr_args: anytype) Expr {
    const impl = struct {
        pub fn compile(comptime ctx: *CompilationContext) Eval {
            const eval_args = exprArgsToEvalArgs(ctx, expr_args);

            return struct {
                pub fn evaluate(ctx_: *Context) Value {
                    std.log.debug(fmt, evalArgsToArgs(ctx_, eval_args));
                    return .void_;
                }
            }.evaluate;
        }
    };

    return .init(compileTypeConst(void), impl.compile);
}

pub fn sleep(comptime duration: std.Io.Duration) Expr(void) {
    return struct {
        pub fn impl(ctx: *Context) void {
            ctx.io.sleep(duration, .real) catch unreachable;
        }
    }.impl;
}

pub fn withContext(comptime f: anytype) Expr(ReturnType(f)) {
    return .init(struct {
        fn compile(comptime _: *CompilationContext) Eval(ReturnType(f)) {
            return f;
        }
    }.compile);
}

pub const create = Expr.init(compileTypeConst(selector.Entity), struct {
    fn compile(comptime _: *CompilationContext) Eval {
        return struct {
            pub fn evaluate(ctx: *Context) selector.Entity {
                const id = ctx.reg.create();
                ctx.last_created = id;
                return .init(id, &ctx.reg);
            }
        }.evaluate;
    }
}.compile);

pub fn let(comptime identifier_: []const u8, comptime value: anytype) Expr {
    const impl = struct {
        pub fn compile(comptime ctx: *CompilationContext) Eval {
            const eval_value = value.compile_(ctx);
            ctx.scope.put(identifier_, struct {
                pub const value_ = value;
            });

            return struct {
                fn evaluate(ctx_: *Context) Value {
                    const value_ = eval_value(ctx_);
                    ctx_.scope.put(identifier_, value_);
                    return .void_;
                }
            }.evaluate;
        }
    };

    return .init(compileTypeConst(void), impl.compile);
}
