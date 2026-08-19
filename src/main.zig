const std = @import("std");
const Io = std.Io;

const gamdev_dsl = @import("gamdev_dsl");
const ct = gamdev_dsl.ct;

const window_size = @Vector(2, f32){ 800, 600 };

const game = ct.seq(&.{
    ct.rl.initWindow(@intFromFloat(window_size)),
    setup,
    ct.until(ct.rl.window_should_close, main_loop),
    ct.log("{}", .{ct.get(.position_)}),
    ct.rl.close_window,
});

const setup = ct.seq(&.{
    ct.select(.create),
    ct.set(.player(.literal(true))),
    ct.set(.size(.literal(.{ 16, 16 }))),
    ct.let("asdf", ct.literal(5.1)),
    ct.log("{}", .{ct.identifier("asdf")}),
});

const main_loop = ct.seq(&.{
    draw,
    update,
});

const draw = ct.seq(&.{
    ct.rl.begin_drawing,
    ct.rl.clearBackground(.black),
    ct.select(.view(.{ct.Body}, .{})),
    ct.rl.drawRectangleV(.literal(.{ 0, 0 }), .literal(.{ 16, 16 }), .literal(.red)),
    // ct.forEachEntity(drawEntity),
    ct.rl.end_drawing,
});

// fn drawEntity(entity: ct.Entity) void {
//     const body = entity.get(ct.Body);
//     rl.drawRectangleV(@bitCast(body.position), @bitCast(body.size), .white);
// }

const update = ct.seq(&.{
    ct.select(.single(ct.Player)),
    player_update,
});

const player_update = ct.seq(&.{
    ct.set(.position(.literal(.{ 0, 0 }))),
});

pub fn main(init: std.process.Init) !void {
    var ctx: ct.Context = .init(init);
    defer ctx.deinit();
    ct.evaluate(ct.compile(game), &ctx);

    // var game = gamdev_dsl.Game.init(init, "Gamedev test", .{ 800, 600 });
    // defer game.deinit();
    //
    // game.setup();
    //
    // const player = game.create(&.{});
    // const ctx = game.single(player.id);
    // ctx.apply(.seq(&.{
    //     .set(.size(.literal(.{ 2, 2 }))),
    //     // setSizeToTileSize,
    // }));
    //
    // game.run();
}

// const setSizeToTileSize = Operation.set(.size(.bind(f64, &time, setSizeToTileSize_aux)));
//
// fn setSizeToTileSize_aux(t: f64) Result(WorldVector) {
//     return .literal(.{ @floatCast(t), @floatCast(t) });
// }
