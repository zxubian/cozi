const std = @import("std");
const TimeLimit = @This();

time_limit_ns: u64,
timer: std.time.Timer,

pub fn init(time_limit_ns: u64) !TimeLimit {
    return TimeLimit{
        .time_limit_ns = time_limit_ns,
        .timer = try std.time.Timer.start(),
    };
}

pub const LimitError = error{
    too_long,
};

pub fn remaining(self: *TimeLimit) u64 {
    const current =
        self.timer.read();
    if (current >= self.time_limit_ns) {
        return 0;
    }
    return self.time_limit_ns - current;
}

pub fn check(self: *TimeLimit) !void {
    if (self.remaining() < 0) {
        return LimitError.too_long;
    }
}
