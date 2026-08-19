pub const Value = struct {
    type: type,
    value: *const anyopaque,

    pub const void_ = @This(){
        .type = void,
        .value = &{},
    };

    pub fn init(value: anytype) @This() {
        var type_ = @TypeOf(value);
        if (type_ == comptime_int) type_ = i32;
        if (type_ == comptime_float) type_ = f32;

        return .{ .type = type_, .value = &@as(type_, value) };
    }

    pub fn get(self: @This()) self.type {
        return @as(*const self.type, @ptrCast(@alignCast(self.value))).*;
    }
};
