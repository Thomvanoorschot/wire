const std = @import("std");

const Callback = struct {
    context: *anyopaque,
    cb: *const fn (context: *anyopaque, payload: []const u8) anyerror!void,
};
pub fn Callbacks(comptime U: type) type {
    const enum_fields = @typeInfo(U).@"enum".fields;
    var fields_array: [enum_fields.len]std.builtin.Type.StructField = undefined;

    inline for (enum_fields, 0..) |field, i| {
        fields_array[i] = .{
            .name = field.name,
            .type = Callback,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Callback),
        };
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields_array,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}
