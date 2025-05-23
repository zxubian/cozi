///! MCS Spinlock
/// https://dl.acm.org/doi/10.1016/0020-0190%2893%2990083-L
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const cozi = @import("../root.zig");
const fault = cozi.fault;
const stdlike = fault.stdlike;
const Atomic = stdlike.atomic.Value;
const log = cozi.core.log.scoped(.spinlock);

const Spinlock = @This();

tail: Atomic(?*Node) = .init(null),

const Node = struct {
    is_owner: Atomic(bool) = .init(false),
    next: Atomic(?*Node) = .init(null),
};

pub fn guard(self: *Spinlock) Guard {
    return Guard{
        .spinlock = self,
    };
}

pub const Guard = struct {
    node: Node = .{},
    spinlock: *Spinlock,

    pub inline fn lock(self: *Guard) void {
        self.node = .{};
        return self.spinlock.lock(&self.node);
    }

    pub inline fn unlock(self: *Guard) void {
        self.spinlock.unlock(&self.node);
    }
};

fn lock(self: *Spinlock, node: *Node) void {
    if (self.tail.swap(node, .seq_cst)) |prev_tail| {
        assert(prev_tail != node);
        prev_tail.next.store(node, .seq_cst);
        while (!node.is_owner.load(.seq_cst)) {
            assert(self.tail.load(.seq_cst) != null);
            std.atomic.spinLoopHint();
        }
    } else {
        // We grabbed the lock with no contention.
        // Do not store node.is_owner = true,
        // because nobody will ever reference it.
    }
}

fn unlock(self: *Spinlock, node: *Node) void {
    if (node.next.load(.seq_cst)) |next| {
        next.is_owner.store(true, .seq_cst);
    } else {
        @branchHint(.likely);
        if (self.tail.cmpxchgStrong(
            node,
            null,
            .seq_cst,
            .seq_cst,
        )) |new_tail| {
            // We're no longer the tail.
            // This means that another new node will attach itself
            // as "next" to our node soon.
            // Wait for the new node to become visible to us,
            // then pass the lock to it.
            @branchHint(.unlikely);
            assert(new_tail != null);
            // log.debug("unlock from {*} failed. New tail: {*}", .{ node, new_tail.? });
            var next: ?*Node = node.next.load(.seq_cst);
            while (next == null) : (next = node.next.load(.seq_cst)) {
                assert(self.tail.load(.seq_cst) != null);
                std.atomic.spinLoopHint();
            }
            next.?.is_owner.store(true, .seq_cst);
        } else {
            // Unlocked without contention.
        }
    }
}

test {
    _ = @import("./spinlock/tests.zig");
}
