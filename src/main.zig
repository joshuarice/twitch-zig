const std = @import("std");

fn handlePing(writer: anytype) !void {
    const pong_msg = "PONG :tmi.twitch.tv\r\n";
    _ = try writer.write(pong_msg);
    std.debug.print("Responded to PING with PONG\n", .{});
}

fn handlePrivMsg(line: []const u8) void {
    if (std.mem.indexOf(u8, line, "!")) |user_end| {
        const username = line[1..user_end];
        const message = line[std.mem.indexOf(u8, line, "PRIVMSG").?..];
        std.debug.print("{s}: {s}\n", .{ username, message });
        return;
    }
    std.debug.print("Chat message: {s}\n", .{line});
}

fn processLine(line: []const u8, writer: anytype) !void {
    if (std.mem.startsWith(u8, line, "PING")) {
        try handlePing(writer);
        return;
    }

    if (std.mem.indexOf(u8, line, "PRIVMSG")) |_| {
        handlePrivMsg(line);
        return;
    }

    std.debug.print("Server message: {s}\n", .{line});
}

fn setupConnection() !struct { stream: std.net.Stream, writer: std.net.Stream.Writer } {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) @panic("Memory leak detected!");
    }
    const allocator = gpa.allocator();

    const port_str = try std.process.getEnvVarOwned(allocator, "TWITCH_PORT");
    defer allocator.free(port_str);
    const port = try std.fmt.parseInt(u16, port_str, 10);

    const server = try std.process.getEnvVarOwned(allocator, "TWITCH_SERVER");
    defer allocator.free(server);
    const peer = try std.net.Address.parseIp4(server, port);

    const stream = try std.net.tcpConnectToAddress(peer);

    std.debug.print("Attempting to connect to {}\n", .{peer});

    if (stream.handle == -1) {
        std.debug.print("Connection failed\n", .{});
        return error.ConnectionFailed;
    }

    std.debug.print("Successfully connected to {}\n", .{peer});
    std.time.sleep(std.time.ns_per_s / 2);

    return .{ .stream = stream, .writer = stream.writer() };
}

fn sendInitialMessages(writer: anytype, allocator: std.mem.Allocator) !void {
    const oauth_token = try std.process.getEnvVarOwned(allocator, "TWITCH_OAUTH_TOKEN");
    defer allocator.free(oauth_token);
    const nick = try std.process.getEnvVarOwned(allocator, "TWITCH_NICKNAME");
    defer allocator.free(nick);

    const messages = [_][]const u8{
        try std.fmt.allocPrint(allocator, "PASS oauth:{s}\r\n", .{oauth_token}),
        try std.fmt.allocPrint(allocator, "NICK {s}\r\n", .{nick}),
        try std.fmt.allocPrint(allocator, "JOIN #{s}\r\n", .{nick}),
    };
    defer {
        for (messages) |msg| {
            allocator.free(msg);
        }
    }

    for (messages) |msg| {
        _ = try writer.write(msg);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) @panic("Memory leak detected!");
    }
    const allocator = gpa.allocator();

    const conn = try setupConnection();
    defer conn.stream.close();

    try sendInitialMessages(conn.writer, allocator);

    var reader = conn.stream.reader();
    while (true) {
        const line = reader.readUntilDelimiterAlloc(allocator, '\n', std.math.maxInt(usize)) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        defer allocator.free(line);

        try processLine(line, conn.writer);
    }
}
