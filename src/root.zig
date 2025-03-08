const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const print = std.debug.print;
const MPSCRingBuffer = @import("shm/mpsc_shm_ringbuf.zig").MPSCRingBuffer;
const SPMCRingBuffer = @import("shm/spmc_shm_ringbuf.zig").SPMCRingBuffer;
const RingBufferType = @import("ringbuf.zig").RingBufferType;
const print_err = std.io.getStdErr().writer().write;

const Role = enum {
    master,
    worker,
    not_connected,
};

const Message = struct {};
threadlocal var worker: ?u8 = null;
threadlocal var role: Role = .not_connected;
const mpsc_path = "/mpsc_buffer";

const StateMachine = enum {
    const Self = @This();
    flush,
    store,
    fill,
    fn next(self: *Self) StateMachine {
        switch (self) {
            .flush => return .fill,
            .fill => return .store,
            .store => return .flush,
        }
    }
};

/// Sets up a new instance of ZigPipe this makes you master needs to be no other master.
export fn init() !void {
    //FIXME: Add a check for if there is another master.
    if (role != .not_connected) {
        return error.AlreadyConnectedToCluster;
    }
    role = .master;
    var mspc_buffer = try MPSCRingBuffer(Message, 1000, .Consumer, mpsc_path).init();
    defer mspc_buffer.deinit();
    var spmc_buffer = try SPMCRingBuffer(Message, 1000, .Producer, mpsc_path).init();
    defer spmc_buffer.deinit();
    var buffer = RingBufferType(Message, 1000);

    // Main event loop
    var sleep_counter: usize = 0;
    while (true) {
        if (sleep_counter > 1000) {
            print_err("Seems like we are in a deadlock");
            return error.DeadLockError; // FIXME: How can we handle this error?
        }
        if (!spmc_buffer.full() and !buffer.empty()) {
            if (buffer.head()) |item| {
                spmc_buffer.push(item);
                buffer.advance_head();
                sleep_counter = 0;
            }
        } else if (!buffer.full) {
            if (mspc_buffer.pop()) |item| {
                buffer.push(item);
                mspc_buffer.advance_tail();
                sleep_counter = 0;
            } else |err| {
                //buffer is empty
                print("Buffer is empty, sleeping, {any}", .{err});
                std.time.sleep(50_000); // Sleep for 50 ms
                sleep_counter = 0;
            }
        } else {
            print("Both sides full, sleeping", .{});
            sleep_counter += 1;
            std.time.sleep(10_000); // Sleep for 10 ms
        }
    }
}

const ExternalAddress = struct {
    ip_address: ?u8,
    port: ?u16,
};

/// Joins a cluster and optinally registers a worker (if dissconected)
/// TODO: Add support for ip_address, zombie pid problem?
export fn join(cluster_id: u8, worker_pid: ?u8, ext_adrs: ExternalAddress) u8 {
    if (worker_pid) {
        worker = worker_pid;
    }
    _ = cluster_id;
    _ = ext_adrs;
    return worker_pid orelse "hello";
}

/// For the master node to register a worker that has joined. (Maybe just watch the mpsc_shm for this?)
export fn register(worker_id: u8) void {
    assert(role == .master);
    worker = worker_id;
}

export fn disconnect() bool {
    return true;
}
