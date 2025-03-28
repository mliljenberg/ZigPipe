const std = @import("std");
const print = std.debug.print;
const IO_Uring = linux.IoUring;
const os = std.os;
const posix = std.posix;
const linux = os.linux;
const io_uring_cqe = linux.io_uring_cqe;
const io_uring_sqe = linux.io_uring_sqe;
const IO = @import("./io.zig").IO;
const fd_t = posix.fd_t;
pub const socket_t = posix.socket_t;

const Actions = enum {
    openat,
    write,
};

const Timeout = struct {
    const Self = @This();
    name: []const u8,
    threashold: usize,
    current_tick: usize,

    fn tick(self: *Self) void {
        self.current_tick += 1;
    }

    fn fired(self: *Self) bool {
        return self.current_tick >= self.threashold;
    }
};

const Events = struct {
    const Self = @This();
    io: *IO,
    fast_ticker: Timeout,
    slow_ticker: Timeout,

    fn slowPrint(self: *Self) !void {
        print("slow printing {}\n", .{self.slow_ticker.current_tick});
        self.slow_ticker.current_tick = 0;
        const fd = std.fs.cwd().fd;
        const flags: linux.O = .{ .CLOEXEC = true, .ACCMODE = .RDWR, .CREAT = true };
        const mode: posix.mode_t = 0o666;
        sqe.prep_openat(
            fd,
            filename ++ ".txt",
            flags,
            mode,
        );
    }

    fn fastPrint(self: *Self) !void {
        self.fast_ticker.current_tick = 0;
        const cqe = self.io.ring.copy_cqe() catch {
            print("No cqe", .{});
            return;
        };
        const a: Actions = @enumFromInt(cqe.user_data);

        if (cqe.res <= 0) std.debug.print("\ncqe_openat.res={}\n", .{cqe.res});
        print("CQE: {}\n{any}\n", .{ a, cqe.res });
        const fd: fd_t = @intCast(cqe.res);
        const sqe = try self.io.ring.get_sqe();
        sqe.prep_write(fd, "Hello, World!", 0);
        sqe.user_data = @intFromEnum(Actions.write);
        _ = try self.io.ring.submit();
    }

    fn createFile(_: *Self, sqe: *io_uring_sqe, comptime filename: []const u8) void {
        const fd = std.fs.cwd().fd;
        const flags: linux.O = .{ .CLOEXEC = true, .ACCMODE = .RDWR, .CREAT = true };
        const mode: posix.mode_t = 0o666;
        sqe.prep_openat(
            fd,
            filename ++ ".txt",
            flags,
            mode,
        );
        sqe.user_data = @intFromEnum(Actions.openat);
    }

    fn writeToFile(_: *Self, sqe: *io_uring_sqe) void {
        const fd = std.fs.cwd();
        const buf = "Hello, World!";
        sqe.prep_write(fd, buf, buf.len, 0);
    }

    pub fn init(io: *IO) Self {
        return .{
            .io = io,
            .fast_ticker = .{ .name = "fast_ticker", .threashold = 11, .current_tick = 0 },
            .slow_ticker = .{ .name = "slow_ticker", .threashold = 10, .current_tick = 0 },
        };
    }
    pub fn tick(self: *Self) !void {
        const timeouts = .{
            .{
                &self.fast_ticker, fastPrint,
            },
            .{
                &self.slow_ticker, slowPrint,
            },
        };
        // Check tasks completed from callback?

        inline for (timeouts) |timeout| {
            timeout[0].tick();
        }
        inline for (timeouts) |timeout| {
            if (timeout[0].fired()) try timeout[1](self);
        }

        // Read from ring, queue to io queue.
        // Read from cq queue, update/write ring.
        // Flush and wait??
    }
};

pub fn main() !void {
    var io = try IO.init(32, 0);
    var events = Events.init(&io);
    while (true) {
        try events.tick();
        try io.run_for_ns(100);
    }
}
