const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const mem = std.mem;
const posix = std.posix;
const print = std.debug.print;
const assert = std.debug.assert;

pub const SharedMemError = error{
    ShmOpenFailed,
    FtruncateFailed,
    ChmodFailed,
    ShmUnlinkFailed,
} || posix.MMapError || posix.TruncateError;

pub fn SharedMem(comptime T: type, comptime num_items: usize) type {
    if (builtin.target.os.tag == .windows) {
        @compileError("Windows is not supported");
    }
    const size = @sizeOf(T) * num_items;
    return struct {
        const Self = @This();
        path: [*:0]const u8,
        mmap_slice: []align(std.heap.page_size_min) u8 = undefined,
        master: bool = false,
        fd: c_int = undefined,

        /// Creates a shared memory object. also creates the shared memory file if master is true.
        pub fn open(
            self: *Self,
        ) SharedMemError![*]align(std.heap.page_size_min) u8 {
            const path_slice = std.mem.span(self.path);
            assert(!std.mem.eql(u8, path_slice, ""));
            const flags: posix.O = if (self.master) .{ .CREAT = true, .ACCMODE = .RDWR, .TRUNC = true } else .{ .ACCMODE = .RDWR };
            const fd = c.shm_open(self.path, @as(c_int, @bitCast(flags)), c.S.IRUSR | c.S.IWUSR);
            if (fd == -1) {
                const err = std.posix.errno(fd);
                print("shm_open failed with error code: {}.\n", .{err});

                return SharedMemError.ShmOpenFailed;
            }
            self.fd = fd;

            if (self.master) {
                errdefer _ = c.shm_unlink(self.path);
            }

            errdefer _ = c.close(fd);

            if (self.master) {
                try posix.ftruncate(fd, @intCast(size));
            }

            self.mmap_slice = try posix.mmap(null, size, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);
            errdefer posix.munmap(self.mmap_slice);

            return self.mmap_slice.ptr;
        }

        pub fn deinit(self: *Self) void {
            posix.munmap(self.mmap_slice);

            if (self.master) {
                if (c.shm_unlink(self.path) == -1) {
                    print("Failed to unlink shared memory\n", .{});
                }
                _ = c.close(self.fd);
            }
        }
    };
}

const expect = std.testing.expect;

test "SharedMem" {
    const FixedMessage = struct {
        id: u32,
    };
    const mes = FixedMessage{ .id = 1 };
    const mes2 = FixedMessage{ .id = 2 };

    var shm = SharedMem(FixedMessage, 2){ .master = true, .path = "/testshm1" };
    const mmap_ptr = try shm.open();
    defer shm.deinit();

    var messages: *[2]FixedMessage = @as([*]FixedMessage, @ptrCast(@alignCast(mmap_ptr)))[0..2];

    // Initialize the message
    messages[0] = mes;
    messages[1] = mes2;
    try expect(messages[0].id == 1);
    try expect(messages[1].id == 2);

    var thread = try std.Thread.spawn(.{}, shared_mem_test_thread, .{});
    thread.join();
    try expect(messages[0].id == 1);
    try expect(messages[1].id == 42);
}

fn shared_mem_test_thread() !void {
    const FixedMessage = struct {
        id: u32,
    };
    var shm = SharedMem(FixedMessage, 2){ .master = false, .path = "/testshm1" };
    const mmap_ptr = try shm.open();
    defer shm.deinit();
    var messages: *[2]FixedMessage = @as([*]FixedMessage, @ptrCast(@alignCast(mmap_ptr)))[0..2];
    try expect(messages[0].id == 1);
    try expect(messages[1].id == 2);
    messages[1].id = 42;
    try expect(messages[1].id == 42);
}
