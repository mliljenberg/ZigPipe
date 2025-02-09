const std = @import("std");
const shared_mem = @import("./shared_mem.zig");

const assert = std.debug.assert;
const print = std.debug.print;
const mem = std.mem;

const UserType = enum {
    Consumer, // Consumer is master and has to start first
    Producer,
};

/// Single Consumer single Producer Shared memory ringbuffer.
pub fn SPSCShmRingBuffer(comptime T: type, comptime len: usize, comptime user_type: UserType) type {
    return struct {
        const Self = @This();
        tail_idx: *u64 = undefined,
        head_idx: *u64 = undefined,
        user_type: UserType = user_type,
        len: u64 = len,
        type_size: usize = @sizeOf(T),
        total_size: usize = @sizeOf(T) * len,
        buffer: [*]T,
        shm: shared_mem.SharedMem(T, len),

        pub fn init() !Self {
            var shm = shared_mem.SharedMem(T, len){ .master = user_type == .Consumer, .path = "/shm_ring_buffer" };
            const mmap = try shm.open();
            errdefer shm.deinit();
            const header_size = @sizeOf(u64);
            const head: *u64 = @ptrCast(@alignCast(mmap));
            const tail: *u64 = @ptrCast(@alignCast(mmap + header_size));
            const buffer: [*]T = @as([*]T, @ptrCast(@alignCast(mmap + header_size * 2)));
            return Self{ .tail_idx = tail, .head_idx = head, .buffer = buffer, .shm = shm };
        }

        pub fn deinit(self: *Self) void {
            self.shm.deinit();
        }

        pub inline fn max_write_spots(self: *const Self) u64 {
            return (self.tail_idx.* + self.len) - self.head_idx.*;
        }

        pub inline fn advance_tail(self: *Self) error{NoSpaceLeft}!void {
            comptime assert(user_type == .Consumer);
            if (self.tail_idx.* == self.head_idx.*) return error.NoSpaceLeft;
            self.tail_idx.* += 1;
            assert(self.tail_idx.* <= self.head_idx.*);
        }

        pub inline fn advance_tail_count(self: *Self, count: usize) error{NoSpaceLeft}!void {
            comptime assert(user_type == .Consumer);
            assert(count > 0);
            if (self.tail_idx.* + count > self.head_idx.*) return error.NoSpaceLeft;
            self.tail_idx.* += count;
            assert(self.tail_idx.* <= self.head_idx.*);
        }

        inline fn advance_head(self: *Self) void {
            assert(user_type == .Producer);
            self.overflow_fix();
            assert((self.tail_idx.* + self.len) > self.head_idx.*);
            self.head_idx.* += 1;
            assert((self.tail_idx.* + self.len) >= self.head_idx.*);
        }

        pub inline fn advance_head_count(self: *Self, count: usize) error{NoSpaceLeft}!void {
            assert(user_type == .Producer);
            if ((self.head_idx.* + count) > self.tail_idx.* + self.len) return error.NoSpaceLeft;
            self.head_idx.* += count;
            assert(self.tail_idx.* + self.len <= self.head_idx.*);
        }

        pub fn get_ptr(self: *const Self, index: usize) error{IndexOutOfBounds}!*T {
            if (index < self.tail_idx.* or index > self.head_idx.*) return error.IndexOutOfBounds;
            return &self.buffer[index % self.len];
        }

        pub fn get(self: *const Self, index: usize) error{IndexOutOfBounds}!T {
            if (index < self.tail_idx.* or index > self.head_idx.*) return error.IndexOutOfBounds;
            return self.buffer[index % self.len];
        }

        pub fn get_tail(self: *Self) error{Empty}!T {
            if (self.tail_idx.* == self.head_idx.*) return error.Empty;
            const ret = self.get(self.tail_idx.*) catch {
                unreachable;
            };
            self.advance_tail() catch {
                unreachable;
            };
            return ret;
        }

        pub fn get_batch_from_tail(self: *const Self, comptime count: usize) error{ ZeroCountNotAllowed, IndexOutOfBounds }![]T {
            if (count == 0) return error.ZeroCountNotAllowed;
            const max_req_idx = self.tail_idx.* + count;
            if (max_req_idx > self.head_idx.*) return error.IndexOutOfBounds;
            const start = self.tail_idx.* % self.len;
            const end = start + count;
            var result: [count]T = undefined;
            if (end <= self.len) {
                @memcpy(&result, self.buffer[start..end]);
            } else {
                const first_part_len = self.len - start;
                @memcpy(result[0..first_part_len], self.buffer[start..]);
                @memcpy(result[first_part_len..], self.buffer[0..(end % self.len)]);
            }
            return &result;
        }
        // pub fn get_batch_ptr(self: *const Self, index_from: usize, index_to: usize) ?[*]T {}

        pub fn push(self: *Self, item: T) error{NoSpaceLeft}!void {
            assert(user_type == .Producer);
            self.overflow_fix();
            const current_head = self.head_idx.*;
            if (self.head_idx.* == self.max_idx()) return error.NoSpaceLeft;
            self.buffer[self.head_idx.* % self.len] = item;
            self.advance_head();
            assert(self.head_idx.* <= self.max_idx());
            assert(self.head_idx.* != current_head);
        }

        // TODO: bench with and without this.
        inline fn overflow_fix(self: *const Self) void {
            if (self.head_idx.* == std.math.maxInt(@TypeOf(self.head_idx.*))) {
                self.head_idx.* %= self.len;
                self.tail_idx.* %= self.len;
            }
        }

        pub fn push_batch(self: *Self, items: []const T) error{NoSpaceLeft}!void {
            assert(user_type == .Producer);
            // if adding to head will create overflow we reset index to remainder;
            if (self.head_idx.* >= std.math.maxInt(@TypeOf(self.head_idx.*)) - items.len) {
                self.head_idx.* %= self.len;
                self.tail_idx.* %= self.len;
            }

            const requested_max_idx = self.head_idx.* + items.len;
            if (requested_max_idx > self.max_idx()) return error.NoSpaceLeft;
            const start = self.head_idx.* % self.len;
            const end = start + items.len;

            if (end <= self.len) {
                @memcpy(self.buffer[start..end], items);
            } else {
                const first_part = self.len - start;
                @memcpy(self.buffer[start..], items[0..first_part]);
                @memcpy(self.buffer[0..], items[first_part..]);
            }

            self.head_idx.* = requested_max_idx;
        }

        /// FIXME: Remove only here for debug purposes
        pub fn print(self: *const Self) void {
            for (self.buffer[0..self.len]) |item| {
                std.debug.print("Value: {}\n", .{item});
            }
        }

        inline fn max_idx(self: *const Self) u64 {
            return self.tail_idx.* + self.len;
        }
    };
}

const expect = std.testing.expect;

test "basic test" {
    const TestStruct = struct {
        id: i32,
    };
    var consumer = try SPSCShmRingBuffer(TestStruct, 10, UserType.Consumer).init();
    defer consumer.deinit();
    var producer = try SPSCShmRingBuffer(TestStruct, 10, UserType.Producer).init();
    defer producer.deinit();
    try producer.push(.{ .id = 1 });
    try producer.push(.{ .id = 2 });
    const c_message = try consumer.get(0);
    const c_message2 = try consumer.get(1);
    try expect(c_message.id == 1);
    try expect(c_message2.id == 2);

    try consumer.advance_tail();
    const c_message_error = consumer.get(0);
    try std.testing.expectError(error.IndexOutOfBounds, c_message_error);
    const mess = try consumer.get_ptr(1);
    mess.*.id = 42;
    const check = try consumer.get_tail();
    try expect(check.id == 42);

    const new_items = [_]TestStruct{
        .{ .id = 3 },
        .{ .id = 4 },
        .{ .id = 5 },
        .{ .id = 6 },
        .{ .id = 7 },
    };

    try producer.push_batch(&new_items);
    const mess2 = try consumer.get_ptr(5);
    mess2.*.id = 69;
    const check2 = try consumer.get(5);
    try expect(check2.id == 69);
    const new_items2 = [_]TestStruct{
        .{ .id = 7 },
        .{ .id = 8 },
        .{ .id = 9 },
        .{ .id = 10 },
    };

    try producer.push_batch(&new_items2);
    const full_err = producer.push(.{ .id = 2 });
    try std.testing.expectError(error.NoSpaceLeft, full_err);

    const full_err2 = producer.push_batch(&new_items2);
    try std.testing.expectError(error.NoSpaceLeft, full_err2);
}

test "basic threaded test" {
    const TestStruct = struct {
        id: i32,
    };
    var consumer = try SPSCShmRingBuffer(TestStruct, 10, UserType.Consumer).init();
    defer consumer.deinit();
    const thread = try std.Thread.spawn(.{}, basic_thread, .{});
    thread.join();

    const c_message = try consumer.get(0);
    const c_message2 = try consumer.get(1);
    try expect(c_message.id == 1);
    try expect(c_message2.id == 2);
    try consumer.advance_tail();

    const c_message_error = consumer.get(0);
    try std.testing.expectError(error.IndexOutOfBounds, c_message_error);
}

fn basic_thread() !void {
    const TestStruct = struct {
        id: i32,
    };
    var producer = try SPSCShmRingBuffer(TestStruct, 10, UserType.Producer).init();
    defer producer.deinit();
    try producer.push(.{ .id = 1 });
    try producer.push(.{ .id = 2 });
}

test "overflow test" {
    const TestStruct = struct {
        id: i32,
    };
    var consumer = try SPSCShmRingBuffer(TestStruct, 10, UserType.Consumer).init();
    defer consumer.deinit();
    consumer.head_idx.* = std.math.maxInt(@TypeOf(consumer.head_idx.*));
    consumer.tail_idx.* = std.math.maxInt(@TypeOf(consumer.head_idx.*));

    const post_remainder_base = std.math.maxInt(@TypeOf(consumer.head_idx.*)) % consumer.len;
    try expect(consumer.head_idx.* == std.math.maxInt(@TypeOf(consumer.head_idx.*)));

    var producer = try SPSCShmRingBuffer(TestStruct, 10, UserType.Producer).init();
    defer producer.deinit();
    try producer.push(.{ .id = 1 });
    try expect(consumer.head_idx.* == post_remainder_base + 1);
    try expect(consumer.tail_idx.* == post_remainder_base);

    consumer.head_idx.* = std.math.maxInt(@TypeOf(consumer.head_idx.*));
    consumer.tail_idx.* = std.math.maxInt(@TypeOf(consumer.head_idx.*));
    const new_items = [_]TestStruct{
        .{ .id = 2 },
        .{ .id = 3 },
        .{ .id = 4 },
        .{ .id = 5 },
        .{ .id = 6 },
    };

    try producer.push_batch(&new_items);

    try expect(consumer.head_idx.* == post_remainder_base + new_items.len);
    try expect(consumer.tail_idx.* == post_remainder_base);
}
