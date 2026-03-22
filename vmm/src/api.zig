// REST API server for VM configuration and control.
// Listens on a Unix domain socket, accepts HTTP/1.1 requests with JSON bodies.
// Implements a subset of the Firecracker API for pre-boot configuration.

const std = @import("std");
const Io = std.Io;
const http = std.http;
const json = std.json;

const snapshot = @import("snapshot.zig");
const main_mod = @import("main.zig");

const log = std.log.scoped(.api);

/// VM configuration accumulated from API calls.
pub const VmConfig = struct {
    kernel_path: ?[:0]const u8 = null,
    initrd_path: ?[:0]const u8 = null,
    boot_args: ?[:0]const u8 = null,
    disk_path: ?[:0]const u8 = null,
    tap_name: ?[:0]const u8 = null,
    vsock_cid: ?[:0]const u8 = null,
    vsock_uds: ?[:0]const u8 = null,
    mem_size_mib: u32 = 512,
    snapshot_path: ?[:0]const u8 = null,
    mem_file_path: ?[:0]const u8 = null,
};

// JSON request body types
const BootSourceBody = struct {
    kernel_image_path: []const u8,
    boot_args: ?[]const u8 = null,
    initrd_path: ?[]const u8 = null,
};

const DriveBody = struct {
    drive_id: []const u8,
    path_on_host: []const u8,
    is_root_device: bool = false,
    is_read_only: bool = false,
};

const NetIfaceBody = struct {
    iface_id: []const u8,
    host_dev_name: []const u8,
    guest_mac: ?[]const u8 = null,
};

const MachineConfigBody = struct {
    mem_size_mib: ?u32 = null,
};

const VsockBody = struct {
    guest_cid: u64,
    uds_path: []const u8,
};

const SnapshotLoadBody = struct {
    snapshot_path: []const u8,
    mem_file_path: []const u8,
};

const ActionBody = struct {
    action_type: []const u8,
};

const MachineConfigResponse = struct {
    mem_size_mib: u32,
    vcpu_count: u32 = 1,
};

/// Bind a Unix socket: unlink stale file, resolve address, listen.
fn listenUnix(sock_path: []const u8, io: Io) !Io.net.Server {
    if (sock_path.len <= Io.net.UnixAddress.max_len) {
        var path_buf: [Io.net.UnixAddress.max_len + 1]u8 = undefined;
        @memcpy(path_buf[0..sock_path.len], sock_path);
        path_buf[sock_path.len] = 0;
        _ = std.os.linux.unlink(@ptrCast(path_buf[0..sock_path.len :0]));
    }
    const addr = try Io.net.UnixAddress.init(sock_path);
    return addr.listen(io, .{});
}

/// Run the API server. Blocks until InstanceStart is received.
/// Returns the accumulated VM configuration.
pub fn serve(sock_path: []const u8, io: Io, allocator: std.mem.Allocator) !VmConfig {
    var server = try listenUnix(sock_path, io);
    defer server.deinit(io);

    log.info("API listening on {s}", .{sock_path});

    var config: VmConfig = .{};

    // Accept connections and handle requests until InstanceStart
    while (true) {
        const stream = server.accept(io) catch |err| {
            log.err("accept failed: {}", .{err});
            continue;
        };

        const started = handleConnection(stream, io, allocator, &config) catch |err| {
            log.err("connection error: {}", .{err});
            stream.close(io);
            continue;
        };

        stream.close(io);

        if (started) {
            if (config.snapshot_path != null) {
                log.info("InstanceStart received, restoring from snapshot", .{});
                return config;
            }
            if (config.kernel_path == null) {
                log.err("InstanceStart without kernel_image_path or snapshot", .{});
                continue;
            }
            log.info("InstanceStart received, booting VM", .{});
            return config;
        }
    }
}

/// Handle a single connection. May process multiple HTTP requests (keep-alive).
/// Returns true if InstanceStart was received.
fn handleConnection(stream: Io.net.Stream, io: Io, allocator: std.mem.Allocator, config: *VmConfig) !bool {
    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buf);
    var stream_writer = stream.writer(io, &write_buf);

    var http_server = http.Server.init(&stream_reader.interface, &stream_writer.interface);

    // Handle multiple requests on this connection (keep-alive)
    while (true) {
        var request = http_server.receiveHead() catch |err| {
            if (err == error.EndOfStream) return false;
            log.warn("receiveHead failed: {}", .{err});
            return false;
        };

        const result = handleRequest(&request, allocator, config);

        switch (result) {
            .instance_start => return true,
            .ok => {},
            .err => return false,
        }

        if (!request.head.keep_alive) return false;
    }
}

const RequestResult = enum { ok, instance_start, err };

/// Route and handle a single HTTP request.
fn handleRequest(request: *http.Server.Request, allocator: std.mem.Allocator, config: *VmConfig) RequestResult {
    const method = request.head.method;
    const target = request.head.target;

    log.info("{s} {s}", .{ @tagName(method), target });

    // Read request body if present
    var body_buf: [4096]u8 = undefined;
    const body = readBody(request, &body_buf) catch |err| {
        log.err("failed to read body: {}", .{err});
        respondError(request, .bad_request, "failed to read request body");
        return .err;
    };

    // Route
    if (method == .PUT and std.mem.eql(u8, target, "/boot-source")) {
        return handleBootSource(request, body, allocator, config);
    } else if (method == .PUT and std.mem.startsWith(u8, target, "/drives/")) {
        return handleDrive(request, body, allocator, config);
    } else if (method == .PUT and std.mem.startsWith(u8, target, "/network-interfaces/")) {
        return handleNetIface(request, body, allocator, config);
    } else if (method == .PUT and std.mem.eql(u8, target, "/vsock")) {
        return handleVsock(request, body, allocator, config);
    } else if (method == .PUT and std.mem.eql(u8, target, "/machine-config")) {
        return handleMachineConfig(request, body, config);
    } else if (method == .GET and std.mem.eql(u8, target, "/machine-config")) {
        return handleGetMachineConfig(request, config);
    } else if (method == .PUT and std.mem.eql(u8, target, "/actions")) {
        return handleAction(request, body);
    } else if (method == .PUT and std.mem.eql(u8, target, "/snapshot/load")) {
        return handleSnapshotLoad(request, body, allocator, config);
    } else {
        respondError(request, .not_found, "resource not found");
        return .ok;
    }
}

fn handleBootSource(request: *http.Server.Request, body: ?[]const u8, allocator: std.mem.Allocator, config: *VmConfig) RequestResult {
    const data = body orelse {
        respondError(request, .bad_request, "missing request body");
        return .ok;
    };

    const parsed = json.parseFromSlice(BootSourceBody, allocator, data, .{
        .ignore_unknown_fields = true,
    }) catch {
        respondError(request, .bad_request, "invalid JSON");
        return .ok;
    };
    defer parsed.deinit();

    config.kernel_path = allocator.dupeZ(u8, parsed.value.kernel_image_path) catch {
        respondError(request, .internal_server_error, "allocation failed");
        return .err;
    };

    if (parsed.value.initrd_path) |p| {
        config.initrd_path = allocator.dupeZ(u8, p) catch {
            respondError(request, .internal_server_error, "allocation failed");
            return .err;
        };
    }

    if (parsed.value.boot_args) |a| {
        config.boot_args = allocator.dupeZ(u8, a) catch {
            respondError(request, .internal_server_error, "allocation failed");
            return .err;
        };
    }

    respondOk(request);
    return .ok;
}

fn handleDrive(request: *http.Server.Request, body: ?[]const u8, allocator: std.mem.Allocator, config: *VmConfig) RequestResult {
    const data = body orelse {
        respondError(request, .bad_request, "missing request body");
        return .ok;
    };

    const parsed = json.parseFromSlice(DriveBody, allocator, data, .{
        .ignore_unknown_fields = true,
    }) catch {
        respondError(request, .bad_request, "invalid JSON");
        return .ok;
    };
    defer parsed.deinit();

    config.disk_path = allocator.dupeZ(u8, parsed.value.path_on_host) catch {
        respondError(request, .internal_server_error, "allocation failed");
        return .err;
    };

    respondOk(request);
    return .ok;
}

fn handleNetIface(request: *http.Server.Request, body: ?[]const u8, allocator: std.mem.Allocator, config: *VmConfig) RequestResult {
    const data = body orelse {
        respondError(request, .bad_request, "missing request body");
        return .ok;
    };

    const parsed = json.parseFromSlice(NetIfaceBody, allocator, data, .{
        .ignore_unknown_fields = true,
    }) catch {
        respondError(request, .bad_request, "invalid JSON");
        return .ok;
    };
    defer parsed.deinit();

    config.tap_name = allocator.dupeZ(u8, parsed.value.host_dev_name) catch {
        respondError(request, .internal_server_error, "allocation failed");
        return .err;
    };

    respondOk(request);
    return .ok;
}

fn handleVsock(request: *http.Server.Request, body: ?[]const u8, allocator: std.mem.Allocator, config: *VmConfig) RequestResult {
    const data = body orelse {
        respondError(request, .bad_request, "missing request body");
        return .ok;
    };

    const parsed = json.parseFromSlice(VsockBody, allocator, data, .{
        .ignore_unknown_fields = true,
    }) catch {
        respondError(request, .bad_request, "invalid JSON");
        return .ok;
    };
    defer parsed.deinit();

    if (parsed.value.guest_cid < 3) {
        respondError(request, .bad_request, "guest_cid must be >= 3");
        return .ok;
    }

    // Store CID as decimal string
    var cid_buf: [20]u8 = undefined;
    const cid_str = std.fmt.bufPrint(&cid_buf, "{d}", .{parsed.value.guest_cid}) catch {
        respondError(request, .internal_server_error, "format failed");
        return .err;
    };
    config.vsock_cid = allocator.dupeZ(u8, cid_str) catch {
        respondError(request, .internal_server_error, "allocation failed");
        return .err;
    };

    config.vsock_uds = allocator.dupeZ(u8, parsed.value.uds_path) catch {
        respondError(request, .internal_server_error, "allocation failed");
        return .err;
    };

    respondOk(request);
    return .ok;
}

fn handleMachineConfig(request: *http.Server.Request, body: ?[]const u8, config: *VmConfig) RequestResult {
    const data = body orelse {
        respondError(request, .bad_request, "missing request body");
        return .ok;
    };

    // Use a stack allocator for parsing since we only need scalar values
    var parse_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&parse_buf);

    const parsed = json.parseFromSlice(MachineConfigBody, fba.allocator(), data, .{
        .ignore_unknown_fields = true,
    }) catch {
        respondError(request, .bad_request, "invalid JSON");
        return .ok;
    };
    defer parsed.deinit();

    if (parsed.value.mem_size_mib) |m| {
        if (m < 1 or m > 16384) {
            respondError(request, .bad_request, "mem_size_mib must be 1-16384");
            return .ok;
        }
        config.mem_size_mib = m;
    }

    respondOk(request);
    return .ok;
}

fn handleGetMachineConfig(request: *http.Server.Request, config: *const VmConfig) RequestResult {
    const resp = MachineConfigResponse{
        .mem_size_mib = config.mem_size_mib,
    };

    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const body = json.Stringify.valueAlloc(fba.allocator(), resp, .{}) catch {
        respondError(request, .internal_server_error, "serialization failed");
        return .err;
    };

    request.respond(body, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch return .err;
    return .ok;
}

fn handleAction(request: *http.Server.Request, body: ?[]const u8) RequestResult {
    const data = body orelse {
        respondError(request, .bad_request, "missing request body");
        return .ok;
    };

    var parse_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&parse_buf);

    const parsed = json.parseFromSlice(ActionBody, fba.allocator(), data, .{
        .ignore_unknown_fields = true,
    }) catch {
        respondError(request, .bad_request, "invalid JSON");
        return .ok;
    };
    defer parsed.deinit();

    if (std.mem.eql(u8, parsed.value.action_type, "InstanceStart")) {
        respondOk(request);
        return .instance_start;
    } else {
        respondError(request, .bad_request, "unknown action_type");
        return .ok;
    }
}

fn handleSnapshotLoad(request: *http.Server.Request, body: ?[]const u8, allocator: std.mem.Allocator, config: *VmConfig) RequestResult {
    const data = body orelse {
        respondError(request, .bad_request, "missing request body");
        return .ok;
    };

    const parsed = json.parseFromSlice(SnapshotLoadBody, allocator, data, .{
        .ignore_unknown_fields = true,
    }) catch {
        respondError(request, .bad_request, "invalid JSON");
        return .ok;
    };
    defer parsed.deinit();

    // Allocate both paths before assigning to config to avoid partial state on failure
    const sp = allocator.dupeZ(u8, parsed.value.snapshot_path) catch {
        respondError(request, .internal_server_error, "allocation failed");
        return .err;
    };
    const mp = allocator.dupeZ(u8, parsed.value.mem_file_path) catch {
        allocator.free(sp);
        respondError(request, .internal_server_error, "allocation failed");
        return .err;
    };

    config.snapshot_path = sp;
    config.mem_file_path = mp;

    respondOk(request);
    return .ok;
}

/// Read request body into buffer. Returns null if no body.
fn readBody(request: *http.Server.Request, buf: []u8) !?[]const u8 {
    const content_length = request.head.content_length orelse return null;
    if (content_length == 0) return null;
    if (content_length > buf.len) return error.BodyTooLarge;

    var reader_buf: [1024]u8 = undefined;
    var body_reader = request.readerExpectNone(&reader_buf);
    const len: usize = @intCast(content_length);
    body_reader.readSliceAll(buf[0..len]) catch return error.ReadFailed;
    return buf[0..len];
}

fn respondOk(request: *http.Server.Request) void {
    request.respond("", .{
        .status = .no_content,
    }) catch {};
}

fn respondError(request: *http.Server.Request, status: http.Status, msg: []const u8) void {
    // Build error JSON manually to avoid allocator dependency
    var buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{{\"fault_message\":\"{s}\"}}", .{msg}) catch {
        request.respond("", .{ .status = status }) catch {};
        return;
    };

    request.respond(body, .{
        .status = status,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch {};
}

// --- Post-boot API ---
// After the VM is running, this server handles live operations:
// PATCH /vm          — pause or resume the vCPU
// PUT /snapshot/create — save VM state to disk (VM must be paused first)
// GET /vm            — query VM status (running/paused)

const VmStateBody = struct {
    state: []const u8, // "Paused" or "Resumed"
};

const SnapshotCreateBody = struct {
    snapshot_type: []const u8 = "Full",
    snapshot_path: []const u8 = "snapshot.vmstate",
    mem_file_path: []const u8 = "snapshot.mem",
};

/// Run the post-boot API server. Accepts connections until the VM exits.
pub fn servePostBoot(
    sock_path: []const u8,
    io: Io,
    allocator: std.mem.Allocator,
    runtime: *main_mod.VmRuntime,
) !void {
    var server = try listenUnix(sock_path, io);
    defer server.deinit(io);

    log.info("post-boot API listening on {s}", .{sock_path});

    while (!runtime.exited.load(.acquire)) {
        const stream = server.accept(io) catch |err| {
            log.err("accept failed: {}", .{err});
            continue;
        };

        handlePostBootConnection(stream, io, allocator, runtime) catch |err| {
            log.err("post-boot connection error: {}", .{err});
        };

        stream.close(io);
    }

    log.info("VM exited, post-boot API shutting down", .{});
}

fn handlePostBootConnection(
    stream: Io.net.Stream,
    io: Io,
    allocator: std.mem.Allocator,
    runtime: *main_mod.VmRuntime,
) !void {
    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buf);
    var stream_writer = stream.writer(io, &write_buf);
    var http_server = http.Server.init(&stream_reader.interface, &stream_writer.interface);

    while (true) {
        var request = http_server.receiveHead() catch |err| {
            if (err == error.EndOfStream) return;
            log.warn("receiveHead failed: {}", .{err});
            return;
        };

        handlePostBootRequest(&request, allocator, runtime);

        if (!request.head.keep_alive) return;
    }
}

fn handlePostBootRequest(
    request: *http.Server.Request,
    allocator: std.mem.Allocator,
    runtime: *main_mod.VmRuntime,
) void {
    const method = request.head.method;
    const target = request.head.target;

    log.info("{s} {s}", .{ @tagName(method), target });

    var body_buf: [4096]u8 = undefined;
    const body = readBody(request, &body_buf) catch {
        respondError(request, .bad_request, "failed to read request body");
        return;
    };

    if (method == .PATCH and std.mem.eql(u8, target, "/vm")) {
        handleVmPatch(request, body, allocator, runtime);
    } else if (method == .PUT and std.mem.eql(u8, target, "/snapshot/create")) {
        handleSnapshotCreate(request, body, allocator, runtime);
    } else if (method == .GET and std.mem.eql(u8, target, "/vm")) {
        handleVmGet(request, runtime);
    } else if (method == .PUT and std.mem.eql(u8, target, "/actions")) {
        handlePostBootAction(request, body, allocator, runtime);
    } else {
        respondError(request, .not_found, "resource not found");
    }
}

fn handleVmPatch(
    request: *http.Server.Request,
    body: ?[]const u8,
    allocator: std.mem.Allocator,
    runtime: *main_mod.VmRuntime,
) void {
    const data = body orelse {
        respondError(request, .bad_request, "missing request body");
        return;
    };

    const parsed = json.parseFromSlice(VmStateBody, allocator, data, .{
        .ignore_unknown_fields = true,
    }) catch {
        respondError(request, .bad_request, "invalid JSON");
        return;
    };
    defer parsed.deinit();

    if (std.mem.eql(u8, parsed.value.state, "Paused")) {
        // Poke the vCPU first so KVM_RUN returns -EINTR.
        // Must happen before the release-store on paused so the
        // run loop's acquire-load sees both writes.
        runtime.vcpu.kvm_run.immediate_exit = 1;

        // Atomically transition false→true; rejects concurrent pause requests
        if (runtime.paused.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
            runtime.vcpu.kvm_run.immediate_exit = 0;
            respondError(request, .bad_request, "VM is already paused");
            return;
        }

        // Kick the vCPU thread out of a blocking KVM_RUN (e.g., guest in HLT).
        // immediate_exit only takes effect on the *next* KVM_RUN call, so if
        // the vCPU is already blocked we need a signal to force -EINTR.
        runtime.kickVcpu();

        // Wait for the run loop to acknowledge it has left KVM_RUN
        while (!runtime.ack_paused.load(.acquire)) {
            if (runtime.exited.load(.acquire)) {
                runtime.paused.store(false, .release);
                respondError(request, .bad_request, "VM has exited");
                return;
            }
            std.atomic.spinLoopHint();
        }
        log.info("VM paused", .{});
        respondOk(request);
    } else if (std.mem.eql(u8, parsed.value.state, "Resumed")) {
        // Clear ack_paused first so the next pause must wait for a fresh ack
        runtime.ack_paused.store(false, .release);

        // Atomically transition true→false; rejects if not paused
        if (runtime.paused.cmpxchgStrong(true, false, .acq_rel, .acquire) != null) {
            respondError(request, .bad_request, "VM is not paused");
            return;
        }
        log.info("VM resumed", .{});
        respondOk(request);
    } else {
        respondError(request, .bad_request, "state must be 'Paused' or 'Resumed'");
    }
}

fn handleSnapshotCreate(
    request: *http.Server.Request,
    body: ?[]const u8,
    allocator: std.mem.Allocator,
    runtime: *main_mod.VmRuntime,
) void {
    if (!runtime.paused.load(.acquire)) {
        respondError(request, .bad_request, "VM must be paused before creating a snapshot");
        return;
    }

    // Buffers for sentinel-terminated paths — must outlive the snapshot.save() call
    var sp_buf: [256]u8 = undefined;
    var mp_buf: [256]u8 = undefined;
    var vmstate_path: [*:0]const u8 = "snapshot.vmstate";
    var mem_path: [*:0]const u8 = "snapshot.mem";

    if (body) |data| {
        const parsed = json.parseFromSlice(SnapshotCreateBody, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch {
            respondError(request, .bad_request, "invalid JSON");
            return;
        };
        defer parsed.deinit();

        if (parsed.value.snapshot_path.len >= sp_buf.len) {
            respondError(request, .bad_request, "snapshot_path too long");
            return;
        }
        @memcpy(sp_buf[0..parsed.value.snapshot_path.len], parsed.value.snapshot_path);
        sp_buf[parsed.value.snapshot_path.len] = 0;
        vmstate_path = @ptrCast(sp_buf[0..parsed.value.snapshot_path.len :0]);

        if (parsed.value.mem_file_path.len >= mp_buf.len) {
            respondError(request, .bad_request, "mem_file_path too long");
            return;
        }
        @memcpy(mp_buf[0..parsed.value.mem_file_path.len], parsed.value.mem_file_path);
        mp_buf[parsed.value.mem_file_path.len] = 0;
        mem_path = @ptrCast(mp_buf[0..parsed.value.mem_file_path.len :0]);
    }

    // vCPU is paused (not in KVM_RUN), safe to read all state
    snapshot.save(
        vmstate_path,
        mem_path,
        runtime.vcpu,
        runtime.vm,
        runtime.mem,
        runtime.serial,
        runtime.devices,
        runtime.device_count,
    ) catch |err| {
        log.err("snapshot save failed: {}", .{err});
        respondError(request, .internal_server_error, "snapshot save failed");
        return;
    };

    respondOk(request);
}

fn handleVmGet(request: *http.Server.Request, runtime: *main_mod.VmRuntime) void {
    const state: []const u8 = if (runtime.exited.load(.acquire))
        "Exited"
    else if (runtime.paused.load(.acquire))
        "Paused"
    else
        "Running";

    var buf: [64]u8 = undefined;
    const resp = std.fmt.bufPrint(&buf, "{{\"state\":\"{s}\"}}", .{state}) catch {
        respondError(request, .internal_server_error, "format failed");
        return;
    };

    request.respond(resp, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch {};
}

/// Handle post-boot actions (e.g., graceful shutdown).
fn handlePostBootAction(
    request: *http.Server.Request,
    body: ?[]const u8,
    allocator: std.mem.Allocator,
    runtime: *main_mod.VmRuntime,
) void {
    const data = body orelse {
        respondError(request, .bad_request, "missing request body");
        return;
    };

    const parsed = json.parseFromSlice(ActionBody, allocator, data, .{
        .ignore_unknown_fields = true,
    }) catch {
        respondError(request, .bad_request, "invalid JSON");
        return;
    };
    defer parsed.deinit();

    if (std.mem.eql(u8, parsed.value.action_type, "SendCtrlAltDel")) {
        // Wait for the VM to exit (up to 5 seconds)
        const linux = std.os.linux;
        var waited: u32 = 0;
        while (waited < 50) : (waited += 1) {
            if (runtime.exited.load(.acquire)) break;
            const ts = linux.timespec{ .sec = 0, .nsec = 100_000_000 }; // 100ms
            _ = linux.nanosleep(&ts, null);
        }

        if (runtime.exited.load(.acquire)) {
            respondOk(request);
        } else {
            respondError(request, .internal_server_error, "VM did not exit within timeout");
        }
    } else {
        respondError(request, .bad_request, "unknown action_type (post-boot supports: SendCtrlAltDel)");
    }
}
