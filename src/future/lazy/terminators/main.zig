pub const get = @import("./get.zig").get;
const State = @import("../main.zig").State;

pub fn Demand(V: type) type {
    return struct {
        result: V = undefined,
        pub fn @"continue"(
            self: *@This(),
            value: V,
            _: State,
        ) void {
            self.result = value;
        }
    };
}
