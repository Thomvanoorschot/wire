const std = @import("std");
const xev = @import("xev");
const svr = @import("server.zig");
const frm = @import("frame.zig");

const TCP = xev.TCP;
const Completion = xev.Completion;
const Loop = xev.Loop;
const Server = svr.Server;
const Frame = frm.Frame;

pub const ClientConnection = struct {
    allocator: std.mem.Allocator,
    server: *Server,
    socket: TCP,
    read_buffer: [1024]u8 = undefined,
    read_completion: Completion = undefined,
    write_contexts: std.ArrayList(*writeContext),
    keep_alive: bool = false,
    write_queue: xev.WriteQueue,

    on_close_ctx: *anyopaque = undefined,
    on_close_cb: ?*const fn (
        self_: ?*anyopaque,
    ) anyerror!void = null,
    is_closing: bool = false,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        server: *Server,
        socket: TCP,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .server = server,
            .socket = socket,
            .write_contexts = std.ArrayList(*writeContext).init(allocator),
            .write_queue = xev.WriteQueue{},
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.write_contexts.deinit();
    }
    pub fn read(
        self: *Self,
        cb_context: *anyopaque,
        comptime read_cb: *const fn (
            self_: ?*anyopaque,
            payload: []const u8,
        ) void,
    ) void {
        const read_userdata = struct {
            self: *Self,
            cb_context: *anyopaque,
        };
        const internal_callback = struct {
            fn inner(
                ud: ?*read_userdata,
                _: *Loop,
                _: *Completion,
                _: TCP,
                buf: xev.ReadBuffer,
                r: xev.ReadError!usize,
            ) xev.CallbackAction {
                const userdata = ud orelse unreachable;
                errdefer userdata.self.allocator.destroy(userdata);
                const inner_self = userdata.self;
                const inner_cb_context = userdata.cb_context;
                const bytes_read = r catch |err| {
                    if (err == error.ConnectionResetByPeer) {
                        inner_self.close(null);
                        return .disarm;
                    }
                    inner_self.close(err);
                    return .disarm;
                };
                var it = std.mem.tokenizeAny(u8, buf.slice[0..bytes_read], "\r\n");

                // TODO: Only for initial message?
                while (it.next()) |line| {
                    if (std.mem.eql(u8, line, "Connection: keep-alive")) {
                        inner_self.keep_alive = true;
                    }
                }
                if (bytes_read == 0) {
                    inner_self.close(null);
                    return .disarm;
                }

                // TODO: Proably make it return something optionally
                read_cb(inner_cb_context, buf.slice[0..bytes_read]);
                if (inner_self.keep_alive) {
                    return .rearm;
                }
                inner_self.allocator.destroy(userdata);

                return .disarm;
            }
        }.inner;
        const rud = self.allocator.create(read_userdata) catch unreachable;
        rud.* = .{ .self = self, .cb_context = cb_context };
        self.socket.read(
            self.server.loop,
            &self.read_completion,
            .{ .slice = &self.read_buffer },
            read_userdata,
            rud,
            internal_callback,
        );
    }

    const writeContext = struct {
        req: xev.WriteRequest = undefined,
        frame: []u8,
    };
    pub fn write(
        self: *Self,
        comptime MessageTypes: type,
        message_type: MessageTypes,
        data: std.ArrayList(u8),
    ) !void {
        const write_context = self.write_contexts.allocator.create(writeContext) catch unreachable;
        write_context.* = .{
            .frame = try Frame.init(
                self.allocator,
                @intFromEnum(message_type),
                data,
            ),
        };

        self.write_contexts.append(write_context) catch unreachable;

        self.socket.queueWrite(
            self.server.loop,
            &self.write_queue,
            &write_context.req,
            .{ .slice = write_context.frame },
            Self,
            self,
            internalWriteCallback,
        );
    }

    fn internalWriteCallback(
        self_: ?*Self,
        _: *Loop,
        c: *Completion,
        _: TCP,
        _: xev.WriteBuffer,
        r: xev.WriteError!usize,
    ) xev.CallbackAction {
        const self = self_ orelse unreachable;

        for (self.write_contexts.items, 0..) |item, idx| {
            if (&item.req.completion == c) {
                self.write_contexts.allocator.free(item.frame);
                self.write_contexts.allocator.destroy(item);
                _ = self.write_contexts.swapRemove(idx);
                break;
            }
        }
        _ = r catch |err| {
            self.close(err);
            return .disarm;
        };
        if (!self.keep_alive) {
            self.close(null);
        }
        return .disarm;
    }
    pub fn setCloseCallback(
        self: *Self,
        on_close_ctx: *anyopaque,
        on_close_cb: *const fn (
            self_: ?*anyopaque,
        ) anyerror!void,
    ) void {
        self.on_close_ctx = on_close_ctx;
        self.on_close_cb = on_close_cb;
    }
    pub fn close(self: *Self, err: ?anyerror) void {
        if (self.is_closing) {
            return;
        }
        if (err) |e| {
            std.log.err("Closing connection with error: {any}", .{e});
        }
        self.is_closing = true;
        self.server.returnConnection(self);
        if (self.on_close_cb) |cb| {
            cb(self.on_close_ctx) catch |close_err| {
                std.log.err("Failed to close connection: {any}", .{close_err});
            };
        }
    }
};
