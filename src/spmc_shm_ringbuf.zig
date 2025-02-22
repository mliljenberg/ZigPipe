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
const COUNT_LIMIT: u32 = 10_000;

pub fn SPMCRingBuffer(comptime T: type, comptime len: usize, comptime user_type: UserType, path: [*:0]const u8) type {
    comptime {
        const header_size = @sizeOf(Atomic(u64)) + @sizeOf(u64) + @sizeOf(Atomic(u64)) + @sizeOf(Atomic(u64));
        const data_size = @sizeOf(T) * len + header_size;
        assert(data_size <= 30_000_000); // L3 cache size TODO: Check system cache size
    }
    return struct {
        const Self = @This();
        // Since only one producer can access this we don't need atomic operations
        head_idx: *u64 = undefined,
        tail_idx: *Atomic(u64) = undefined,
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
            const current_consumers_size = @sizeOf(Atomic(u64));
            const recerved_idxs_size = header_size;

            var shm = shared_mem.SharedMem(T, len){ .master = user_type == .Producer, .path = path };
            const mmap = try shm.open();
            errdefer shm.deinit();
            const tail: *Atomic(u64) = @ptrCast(@alignCast(mmap));
            var position: usize = header_size;
            const head: *u64 = @ptrCast(@alignCast(mmap + position));
            position += tail_size;
            position += current_consumers_size;
            const reserved_idx: *Atomic(u64) = @ptrCast(@alignCast(mmap + position));
            position += recerved_idxs_size;
            const buffer: [*]T = @as([*]T, @ptrCast(@alignCast(mmap + position)));
            if (user_type == .Producer) {
                // We initalize everything here.
                tail.*.store(0, .seq_cst);
                reserved_idx.*.store(0, .seq_cst);
                head.* = 0;
            }
            const self = Self{ .tail_idx = tail, .head_idx = head, .buffer = buffer, .shm = shm, .reserved_idx = reserved_idx };

            return self;
        }

        pub fn deinit(self: *Self) void {
            // FIXME: Right now we do not care if consumer leaves. If they are gone they are gone forever.
            self.shm.deinit();
        }

        /// Gets the tail and increases the index.
        pub fn get_tail(self: *Self) error{Empty}!T {
            assert(user_type == .Consumer);

            // a check if space available.
            var count: u32 = 0;
            while (true) {
                const reserved_idx = self.reserved_idx.*.load(.acquire);
                if (reserved_idx == self.head_idx.*) return error.Empty;

                assert(count < COUNT_LIMIT);
                if (self.reserved_idx.*.cmpxchgWeak(reserved_idx, reserved_idx + 1, .acq_rel, .acquire)) |_| {
                    // CAS failed retry
                    count += 1;
                    continue;
                }
                const ret_val = self.buffer[reserved_idx % self.len];

                count = 0;
                inner: while (true) {
                    assert(count < COUNT_LIMIT);
                    if (self.tail_idx.*.cmpxchgWeak(reserved_idx, reserved_idx + 1, .acq_rel, .acquire)) |_| {
                        // CAS failed retry
                        count += 1;
                        continue :inner;
                    }
                    return ret_val;
                }
            }
        }

        pub fn push(self: *Self, item: T) error{Full}!void {
            assert(user_type == .Producer);
            if (self.head_idx.* == (self.tail_idx.*.load(.acquire) + self.len)) return error.Full;
            assert(self.head_idx.* <= (self.tail_idx.*.load(.acquire) + self.len));
            self.buffer[self.head_idx.* % self.len] = item;
            self.head_idx.* += 1;
        }

        pub fn full(self: Self) bool {
            return self.head_idx.* == (self.tail_idx.*.load(.acquire));
        }
    };
}

const expect = std.testing.expect;
test "spmc" {
    const TestStruct = struct {
        id: usize,
        data: [1000]u8,
    };
    const path = "/shm_ring_test_shm";
    var producer = try SPMCRingBuffer(TestStruct, 1000, .Producer, path).init();

    var consumer = try SPMCRingBuffer(TestStruct, 1000, .Consumer, path).init();
    defer producer.deinit();
    var list: [4]std.Thread = undefined;
    for (0..4) |i| {
        const thread = try std.Thread.spawn(.{}, basic_consumer_test_thread, .{});
        list[i] = thread;
        errdefer thread.join();
    }
    var count: usize = 0;
    while (count < 4000) {
        const message = TestStruct{ .id = count + 1, .data = std.mem.zeroes([1000]u8) };
        try expect(message.id > 0);
        producer.push(message) catch {
            continue;
        };
        count += 1;
    }
    for (list) |thread| {
        thread.join();
    }

    const mes = consumer.get_tail();
    try std.testing.expectError(error.Empty, mes);
}

fn basic_consumer_test_thread() !void {
    var count: usize = 0;
    const TestStruct = struct {
        id: usize,
        data: [1000]u8,
    };

    const path = "/shm_ring_test_shm";
    var consumer = try SPMCRingBuffer(TestStruct, 1000, .Consumer, path).init();
    var sum: u64 = 0;
    while (count < 1000) {
        const message = consumer.get_tail() catch {
            continue;
        };
        sum += message.id;
        count += 1;
    }
    try expect(count == 1000);
}

test "basic_functionality" {
    const TestStruct = struct {
        id: usize,
        data: [1000]u8,
    };

    // Initialize consumer and producer
    var producer = try SPMCRingBuffer(TestStruct, 1000, .Producer, "/test-buff").init();
    defer producer.deinit();
    var consumer = try SPMCRingBuffer(TestStruct, 1000, .Consumer, "/test-buff").init();
    defer consumer.deinit();

    // Test 1: Basic push and consume
    try producer.push(TestStruct{ .id = 1, .data = std.mem.zeroes([1000]u8) });
    try producer.push(TestStruct{ .id = 2, .data = std.mem.zeroes([1000]u8) });
    try producer.push(TestStruct{ .id = 3, .data = std.mem.zeroes([1000]u8) });

    try expect((try consumer.get_tail()).id == 1);
    try expect((try consumer.get_tail()).id == 2);
    try expect((try consumer.get_tail()).id == 3);

    // Test 2: Empty buffer behavior
    try std.testing.expectError(error.Empty, consumer.get_tail());

    // Test 3: Fill buffer to capacity
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try producer.push(TestStruct{
            .id = i + 100,
            .data = std.mem.zeroes([1000]u8),
        });
    }

    // Test 4: Buffer full behavior
    try std.testing.expectError(error.Full, producer.push(TestStruct{
        .id = 9999,
        .data = std.mem.zeroes([1000]u8),
    }));

    // Test 5: Consume all items
    i = 0;
    while (i < 1000) : (i += 1) {
        const item = try consumer.get_tail();
        try expect(item.id == i + 100);
    }

    // Test 6: Verify buffer is empty again
    try std.testing.expectError(error.Empty, consumer.get_tail());

    // Test 7: Push-consume alternation
    try producer.push(TestStruct{ .id = 42, .data = std.mem.zeroes([1000]u8) });
    const item = try consumer.get_tail();
    try expect(item.id == 42);
    try std.testing.expectError(error.Empty, consumer.get_tail());

    // Test 8: Multiple pushes followed by multiple consumes
    const test_count = 10;
    i = 0;
    while (i < test_count) : (i += 1) {
        try producer.push(TestStruct{
            .id = i + 1000,
            .data = std.mem.zeroes([1000]u8),
        });
    }

    i = 0;
    while (i < test_count) : (i += 1) {
        const consumed = try consumer.get_tail();
        try expect(consumed.id == i + 1000);
    }

    // Test 9: Verify final empty state
    try std.testing.expectError(error.Empty, consumer.get_tail());
}
