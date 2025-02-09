/// FIXME: This is working but is not at all fully tested yet!
const std = @import("std");
const shared_mem = @import("./shared_mem.zig");

const assert = std.debug.assert;
const print = std.debug.print;
const mem = std.mem;
const Atomic = std.atomic.Value;

const UserType = enum {
    Consumer, // Consumer is master and has to start first
    Producer,
};

const NO_RESERVATION_VALUE: u64 = std.math.maxInt(u64);

pub fn ShmRingBuffer(comptime T: type, comptime len: usize, comptime user_type: UserType, comptime max_producers: u64, path: [*:0]const u8) type {
    assert(max_producers > 0);
    comptime {
        const header_size = @sizeOf(Atomic(u64)) + @sizeOf(u64) + @sizeOf(Atomic(u64)) + @sizeOf(Atomic(u64));
        const data_size = @sizeOf(T) * len + header_size;
        assert(data_size <= 30_000_000); // L3 cache size TODO: Check system cache size
    }
    return struct {
        const Self = @This();
        // Since only one consumer can access this we don't need atomic operations
        tail_idx: *u64 = undefined,
        head_idx: *Atomic(u64) = undefined,
        user_type: UserType = user_type,
        len: u64 = len,
        type_size: usize = @sizeOf(T),
        total_size: usize = @sizeOf(T) * len,
        buffer: [*]T,
        reserved_idx: *Atomic(u64) = undefined,
        shm: shared_mem.SharedMem(T, len),

        // Ordering is [head, tail, reserved_idx, data]
        pub fn init() !Self {
            const header_size = @sizeOf(Atomic(u64));
            const tail_size = @sizeOf(u64);
            const current_producers_size = @sizeOf(Atomic(u64));
            const recerved_idxs_size = header_size;

            var shm = shared_mem.SharedMem(T, len){ .master = user_type == .Consumer, .path = path };
            const mmap = try shm.open();
            errdefer shm.deinit();
            const head: *Atomic(u64) = @ptrCast(@alignCast(mmap));
            var position: usize = header_size;
            const tail: *u64 = @ptrCast(@alignCast(mmap + position));
            position += tail_size;
            position += current_producers_size;
            const reserved_idx: *Atomic(u64) = @ptrCast(@alignCast(mmap + position));
            position += recerved_idxs_size;
            const buffer: [*]T = @as([*]T, @ptrCast(@alignCast(mmap + position)));
            if (user_type == .Consumer) {
                head.*.store(0, .seq_cst);
                reserved_idx.*.store(0, .seq_cst);
                tail.* = 0;
            }
            const self: Self = .{ .tail_idx = tail, .head_idx = head, .buffer = buffer, .shm = shm, .reserved_idx = reserved_idx };

            return self;
        }

        pub fn deinit(self: *Self) void {
            // FIXME: Right now we do not care if producer leaves. If they are gone they are gone forever.
            self.shm.deinit();
        }

        pub fn get_tail(self: *Self) error{Empty}!T {
            assert(user_type == .Consumer);
            const available_head = self.head_idx.*.load(.acquire);
            const tail_idx = self.tail_idx.*;
            if (available_head == tail_idx) return error.Empty;

            if (available_head < tail_idx) {
                print("tail in get: {} available_head {}\n", .{ tail_idx, available_head });
                unreachable;
            }

            const ret_val = self.buffer[tail_idx % self.len];
            self.tail_idx.* += 1;
            assert(self.tail_idx.* <= available_head);
            return ret_val;
        }

        pub fn push(self: *Self, item: T) error{Full}!void {
            assert(user_type == .Producer);

            // a check if space available.
            while (true) {
                const reserved_idx = self.reserved_idx.*.load(.acquire);
                if (reserved_idx == (self.tail_idx.* + self.len)) return error.Full;
                // If fail it returns current head_idx otherwise it returns null
                if (self.reserved_idx.*.cmpxchgWeak(reserved_idx, reserved_idx + 1, .acq_rel, .acquire)) |_| {
                    // CAS failed retry
                    continue;
                }
                self.buffer[reserved_idx % self.len] = item;
                while (true) {
                    if (self.head_idx.*.cmpxchgWeak(reserved_idx, reserved_idx + 1, .acq_rel, .acquire)) |_| {
                        // CAS failed retry
                        continue;
                    }
                    return;
                }
                return;
            }
        }
    };
}

const expect = std.testing.expect;
test "mpsc" {
    const TestStruct = struct {
        id: usize,
        data: [1000]u8,
    };
    var consumer = try ShmRingBuffer(TestStruct, 1000, .Consumer, 4, "/test-buff").init();
    defer consumer.deinit();
    var list: [4]std.Thread = undefined;
    for (0..4) |i| {
        const thread = try std.Thread.spawn(.{}, basic_test_thread, .{});
        list[i] = thread;
        errdefer thread.join();
    }
    var count: usize = 0;
    var sum: u64 = 0;
    while (count < 1000 * 4) {
        const message = consumer.get_tail() catch {
            continue;
        };
        sum += message.id;
        count += 1;
    }
    for (list) |thread| {
        thread.join();
    }
    try expect(count == 1000 * 4);
    try expect(sum == 2002000);
    const mes = consumer.get_tail();

    try std.testing.expectError(error.Empty, mes);
}

fn basic_test_thread() !void {
    const TestStruct = struct {
        id: usize,
        data: [1000]u8,
    };
    var producer = try ShmRingBuffer(TestStruct, 1000, .Producer, 4, "/test-buff").init();
    // assert(producer.tail_idx.* == 0);
    // assert(producer.head_idx.* == 0);
    defer producer.deinit();
    var count: usize = 0;
    while (count < 1000) {
        const message = TestStruct{ .id = count + 1, .data = std.mem.zeroes([1000]u8) };
        try expect(message.id > 0);
        producer.push(message) catch {
            continue;
        };

        count += 1;
    }
}
