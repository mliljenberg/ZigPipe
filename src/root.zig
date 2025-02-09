const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const Role = enum { master, worker, not_connected };

threadlocal var worker: ?u8 = null;
threadlocal var role: Role = .not_connected;

/// Sets up a new instance of ZigPipe
export fn create(max_num_workers: usize) !void {
    if (role != .not_connected) {
        return error.AlreadyConnectedToCluster;
    }
    role = .master;
    _ = max_num_workers;
}

const ExternalAddress = struct {
    url: []const ?u8,
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
