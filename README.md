# Wire: A TCP Networking Library for Zig

## Overview

Wire is a networking library written in Zig, designed to simplify building TCP-based client-server applications. It leverages Zig's capabilities for memory safety and performance, and integrates with the `xev` event loop for asynchronous I/O operations able to run on a single thread.

## Goals
*   Provide a straightforward API for TCP client and server creation.
*   Implement a simple message framing protocol for clear data exchange.
*   Enable asynchronous, non-blocking network communication.
*   Offer a callback-based mechanism for handling network events.
*   Serve as a practical example of Zig for network programming.

## Architecture

Wire is built around two main components:

*   **`Client`**: Manages a connection to a TCP server. It handles connecting, sending data, and receiving framed messages.
*   **`Server`**: Listens for incoming TCP connections and manages multiple `ClientConnection` instances.
*   **`ClientConnection`**: Represents a connection from a client to the server, handling reading and writing of framed data.
*   **`Frame` / `FrameHeader`**: Defines the structure for messages, where each message is prefixed with a header indicating its type and the length of its payload. This allows for structured communication between client and server.

## Features

*   **Asynchronous Operations**: Utilizes `xev` for non-blocking network I/O.
*   **Message Framing**: Implements a basic framing protocol (message type + payload length) to delineate messages over TCP streams.
*   **Callback-Driven**: Uses callbacks to notify application code of events such as new connections, incoming data, and disconnections.
*   **Memory Management**: Leverages Zig's allocators for explicit memory control.
*   **Client and Server Abstractions**: Provides easy-to-use `Client` and `Server` types.

## Learning Outcomes

This project can provide insights into:
*   Network programming in Zig.
*   Working with event loops (specifically `xev`).
*   Implementing basic network protocols (framing).
*   Zig's error handling and memory management in a networking context.
*   Callback-based event handling.

## Getting Started

(Instructions for integrating and using the Wire library will be added as development progresses.)

## Usage Example

Here's a basic example of how to use the `Client` to connect to a server and handle messages:

```zig
const std = @import("std");
const xev = @import("xev"); // Assuming xev is available
const wire = @import("wire");

// 1. Define the message types your application will use.
//    This enum will be used by the client to dispatch messages to the correct callbacks.
pub const MessageTypes = enum {
    myMessageA,
    myMessageB,
};

// 2. Define callback functions for each message type.
//    These functions will be called when a message of the corresponding type is received.
fn handleMyMessageA(context: ?*anyopaque, payload: []const u8) anyerror!void {
    // 'context' is the optional context pointer provided during client initialization.
    // 'payload' is the raw byte slice of the message.
    // Process payload for myMessageA
    std.debug.print("Received myMessageA: {s}\n", .{payload});
    _ = context; // Avoid unused variable warning if context is not used
}

fn handleMyMessageB(context: ?*anyopaque, payload: []const u8) anyerror!void {
    // Process payload for myMessageB
    std.debug.print("Received myMessageB: {s}\n", .{payload});
    _ = context;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    // 3. Initialize the Client.
    var client = try wire.Client(MessageTypes).init(
        allocator,
        &loop,
        .{ // ClientOptions
            .server_addr = try std.net.Address.parseIp4("127.0.0.1", 8080), // Target server address
            // .keep_alive = false, // Optional: defaults to false
        },
        .{ // Callbacks for each MessageType
            .myMessageA = handleMyMessageA,
            .myMessageB = handleMyMessageB,
        },
        null, // Optional context pointer to be passed to callbacks
    );

    // 4. Connect to the server.
    //    The connection happens asynchronously.
    //    You might want a connection callback in a real application to know when it's established.
    client.connect();

    // 5. Start reading messages from the server.
    //    This tells the client to begin listening for incoming framed messages.
    client.startReading();

    // Run the event loop to process network events.
    try loop.run();
}

```
This example demonstrates:
*   Defining `MessageTypes`.
*   Creating callback functions for these types.
*   Initializing the `wire.Client` with server address, options, and callbacks.
*   Connecting the client using `client.connect()`.
*   Initiating message reading with `client.startReading()`.
*   Running the `xev` event loop.

### Server Usage Example

Here's a basic example of how to use the `Server` to accept connections and handle client messages:

```zig
const std = @import("std");
const xev = @import("xev");
const wire = @import("wire");

// 1. Define message types (must be the same as the client's MessageTypes).
pub const MessageTypes = enum {
    myMessageA,
    myMessageB,
};

// Forward declaration for ConnectionContext if needed for callbacks
const ConnectionContext = struct {
    allocator: std.mem.Allocator,
    client_conn: *wire.ClientConnection,
};

// 2. Implement the callback for when a new client is accepted.
fn serverAcceptCallback(
    server_context: ?*anyopaque, // Context provided during Server.init
    loop: *xev.Loop,
    accept_completion: *xev.Completion,
    client_conn: *wire.ClientConnection,
) xev.CallbackAction {
    _ = loop;
    _ = accept_completion;

    const allocator = @as(*std.mem.Allocator, @ptrCast(@alignCast(server_context))).?;

    std.debug.print("Server: Client connected (fd: {d})\n", .{client_conn.socket.fd});

    // 3. For each connection, set up context and start reading.
    const conn_ctx = allocator.create(ConnectionContext) catch |err| {
        std.debug.print("Server: Failed to allocate context for connection: {any}\n", .{err});
        // client_conn.close(null); // Close if context allocation fails
        return .rearm; // Continue accepting other connections
    };
    conn_ctx.* = .{
        .allocator = allocator,
        .client_conn = client_conn,
    };

    // Set a callback for when this specific client connection closes
    client_conn.setCloseCallback(@ptrCast(conn_ctx), clientCloseCallback);

    // Start reading messages from this client
    client_conn.read(@ptrCast(conn_ctx), clientReadCallback);

    // Server should continue to accept new connections
    return .rearm;
}

// 4. Implement the callback for reading data from a client.
fn clientReadCallback(
    context: ?*anyopaque,
    payload: []const u8,
) void {
    const conn_ctx = @as(*ConnectionContext, @ptrCast(@alignCast(context))).?;
    std.debug.print("Server: Received from client (fd: {d}): {s}\n", .{conn_ctx.client_conn.socket.fd, payload});

    // Example: Echo the message back or send a different response
    const response_payload = "Server acknowledges your message!" catch unreachable; // Using a string literal
    conn_ctx.client_conn.write(
        MessageTypes, // The enum type
        .myMessageA, // The specific message type from the enum
        response_payload,
    ) catch |err| {
        std.debug.print("Server: Failed to write to client (fd: {d}): {any}\n", .{conn_ctx.client_conn.socket.fd, err});
        // The connection might be closed by the write error handler in ClientConnection
    };
}

// 5. Implement the callback for when a client connection is closed.
fn clientCloseCallback(context: ?*anyopaque) anyerror!void {
    const conn_ctx = @as(*ConnectionContext, @ptrCast(@alignCast(context))).?;
    std.debug.print("Server: Client disconnected (fd: {d})\n", .{conn_ctx.client_conn.socket.fd});
    // Deinitialize/free the ConnectionContext
    conn_ctx.allocator.destroy(conn_ctx);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    // 6. Initialize the Server.
    var server = try wire.Server.init(
        allocator,
        &loop,
        .{ // ServerOptions
            .address = try std.net.Address.parseIp4("127.0.0.1", 8080),
            .max_connections = 10,
        },
        @ptrCast(&allocator), // Pass allocator as server context for acceptCallback
        serverAcceptCallback,
    );
    defer server.deinit(); // Ensure server resources are cleaned up

    // 7. Start accepting connections.
    //    This will continuously listen for new clients in the background via the event loop.
    server.accept();
    std.debug.print("Server listening on 127.0.0.1:8080\n", .{});

    // Run the event loop to process network events.
    try loop.run();
}

This server example shows:
*   Initializing `wire.Server` with an address and an `acceptCallback`.
*   The `acceptCallback` is invoked for each new client.
*   Inside `acceptCallback`, `client_conn.read()` is called with a `readCallback` to process incoming data from that specific client.
*   `client_conn.write()` is used to send framed messages back to the client.
*   `client_conn.setCloseCallback()` is used to register a function to be called when the client disconnects, allowing for resource cleanup.

## Project Status

🚧 Early Development – The core client and server components, along with message framing, are implemented. Further development will focus on robustness, features, and examples.