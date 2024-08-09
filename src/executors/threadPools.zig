pub const Compute = @import("./threadPool/compute.zig");
// TODO: add go-like fast threadpool for fibers

test {
    _ = @import("./threadPool/compute.zig");
}
