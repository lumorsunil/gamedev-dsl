const std = @import("std");
const core = @import("comptime-core.zig");
const selector = @import("selector.zig");
const Selector = selector.Selector;

pub const rl = @import("comptime-rl.zig");

pub const Context = core.Context;
pub const CompilationContext = core.CompilationContext;
pub const Entity = selector.Entity;

pub const Player = selector.Player;
pub const Body = selector.Body;

pub const compile = core.compile;
pub const evaluate = core.evaluate;

pub const Expr = core.Expr;
pub const literal = core.literal;
pub const identifier = core.identifier;
pub const lift = core.lift;
pub const closured = core.closured;
pub const closured2 = core.closured2;
pub const noCtx = core.noCtx;

pub const let = core.let;

pub const seq = core.seq;
pub const whil = core.whil;
pub const until = core.until;

pub const map = core.map;
pub const bind = core.bind;

pub const not = core.not;

pub const log = core.log;
pub const sleep = core.sleep;

pub const create = core.create;
pub const set = selector.set;
pub const get = selector.get;
pub const forEachEntity = selector.forEachEntity;

pub const SelectArg = union(enum) {
    create,
    last_created,
    single_: type,
    view_: type,

    pub fn single(comptime T: type) @This() {
        return .{ .single_ = T };
    }

    pub fn view(comptime includes: anytype, comptime excludes: anytype) @This() {
        return .{
            .view_ = struct {
                pub const includes_ = includes;
                pub const excludes_ = excludes;
            },
        };
    }

    pub fn get(comptime self: @This()) Selector {
        return switch (self) {
            .create => .create,
            .last_created => .lastCreated(),
            .single_ => |component| .single(component),
            .view_ => |view_| .view(view_.includes_, view_.excludes_),
        };
    }
};

pub fn select(comptime s: SelectArg) Expr {
    const impl = struct {
        pub fn compile(comptime ctx: *CompilationContext) core.Eval {
            ctx.selector = s.get();
            if (ctx.selector.? == .create) {
                return seq(&.{
                    create,
                    select(.last_created),
                }).compile_(ctx);
            }
            return core.noop;
        }
    };

    return .init(core.compileTypeConst(void), impl.compile);
}
