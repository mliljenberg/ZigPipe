// Since all buffers should have the same interface/scheme we make sure to run the same generic
// tests on all of them here.
const std = @import("std");
const expect = std.testing.expect;
const MPSCRingBuffer = @import("mpsc_shm_ringbuf.zig").MPSCRingBuffer;
const SPMCRingBuffer = @import("spmc_shm_ringbuf.zig").SPMCRingBuffer;
const SPSCRingBuffer = @import("spsc_shm_ringbuf.zig").SPSCRingBuffer;

const TestStruct = struct {
    id: usize,
    data: [1000]u8,
};

fn generic_test(consumer: anytype, producer: anytype) !void {
    // Initialize consumer and producer

    // Test 1: Basic push and consume
    try producer.push(TestStruct{ .id = 1, .data = std.mem.zeroes([1000]u8) });
    try producer.push(TestStruct{ .id = 2, .data = std.mem.zeroes([1000]u8) });
    try producer.push(TestStruct{ .id = 3, .data = std.mem.zeroes([1000]u8) });

    try expect((try consumer.pop()).id == 1);
    try expect((try consumer.pop()).id == 2);
    try expect((try consumer.pop()).id == 3);

    // Test 2: Empty buffer behavior
    try std.testing.expectError(error.Empty, consumer.pop());

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
        const item = try consumer.pop();
        try expect(item.id == i + 100);
    }

    // Test 6: Verify buffer is empty again
    try std.testing.expectError(error.Empty, consumer.pop());

    // Test 7: Push-consume alternation
    try producer.push(TestStruct{ .id = 42, .data = std.mem.zeroes([1000]u8) });
    const item = try consumer.pop();
    try expect(item.id == 42);
    try std.testing.expectError(error.Empty, consumer.pop());

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
        const consumed = try consumer.pop();
        try expect(consumed.id == i + 1000);
    }

    // Test 9: Verify final empty state
    try std.testing.expectError(error.Empty, consumer.pop());
}

test "mpsc" {
    var consumer = try MPSCRingBuffer(TestStruct, 1000, .Consumer, "/test-buff").init();
    defer consumer.deinit();
    var producer = try MPSCRingBuffer(TestStruct, 1000, .Producer, "/test-buff").init();
    defer producer.deinit();
    try generic_test(&consumer, &producer);
}

test "spmc" {
    // Initialize consumer and producer
    var producer = try SPMCRingBuffer(TestStruct, 1000, .Producer, "/test-buff").init();
    defer producer.deinit();
    var consumer = try SPMCRingBuffer(TestStruct, 1000, .Consumer, "/test-buff").init();
    defer consumer.deinit();
    try generic_test(&consumer, &producer);
}

test "spsc" {
    // Initialize consumer and producer
    var producer = try SPSCRingBuffer(TestStruct, 1000, .Producer, "/test-buff").init();
    defer producer.deinit();
    var consumer = try SPSCRingBuffer(TestStruct, 1000, .Consumer, "/test-buff").init();
    defer consumer.deinit();
    try generic_test(&consumer, &producer);
}
