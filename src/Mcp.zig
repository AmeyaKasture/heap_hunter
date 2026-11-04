//! Model Context Protocol (MCP) server for hunt.
//!
//! Implements JSON-RPC 2.0 over stdio using newline-delimited messages. The
//! server exposes each hunt command as an MCP tool and emits
//! `notifications/progress` for long-running operations such as
//! `analyze_heap_dump`.
const std = @import("std");
const Io = std.Io;

const Config = @import("Config.zig").Config;
const McpTools = @import("McpTools.zig");
const Progress = @import("Progress.zig");
const Cli = @import("Cli.zig");

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config_load: *Config.LoadResult,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        config_load: *Config.LoadResult,
    ) Server {
        return .{
            .allocator = allocator,
            .io = io,
            .config_load = config_load,
        };
    }

    pub fn run(self: *Server) !void {
        const stdin_file = Io.File.stdin();
        const stdout_file = Io.File.stdout();

        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader: Io.File.Reader = .init(stdin_file, self.io, &stdin_buf);

        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer: Io.File.Writer = .init(stdout_file, self.io, &stdout_buf);
        const stdout = &stdout_writer.interface;

        // Disable colored CLI output inside the MCP server; stdout must be
        // pure JSON-RPC and stderr should be plain text for logs.
        Cli.setColorsEnabled(false);

        while (true) {
            const line = try readLine(&stdin_reader, self.allocator) orelse break;
            defer self.allocator.free(line);

            if (line.len == 0) continue;

            self.handleMessage(line, stdout) catch |err| {
                log.err("failed to handle MCP message: {s}", .{@errorName(err)});
                continue;
            };
            try stdout_writer.flush();
        }
    }

    fn handleMessage(self: *Server, line: []const u8, stdout: *Io.Writer) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line, .{}) catch {
            try sendError(stdout, null, -32700, "Parse error");
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            try sendError(stdout, null, -32700, "Parse error: message must be a JSON object");
            return;
        }

        const obj = root.object;
        const jsonrpc = obj.get("jsonrpc");
        if (jsonrpc == null or jsonrpc.? != .string or !std.mem.eql(u8, jsonrpc.?.string, "2.0")) {
            try sendError(stdout, obj.get("id"), -32600, "Invalid Request: jsonrpc must be a 2.0 string");
            return;
        }

        const method_val = obj.get("method");
        if (method_val == null or method_val.? != .string) {
            try sendError(stdout, obj.get("id"), -32600, "Invalid Request: method is required");
            return;
        }
        const method = method_val.?.string;
        const id = obj.get("id");
        const params = obj.get("params");

        if (std.mem.eql(u8, method, "initialize")) {
            try self.sendInitializeResponse(stdout, id, params);
        } else if (std.mem.eql(u8, method, "initialized")) {
            // No response required for notifications.
        } else if (std.mem.eql(u8, method, "notifications/cancelled")) {
            // Cancellation is not implemented yet.
        } else if (std.mem.eql(u8, method, "tools/list")) {
            try self.sendToolsList(stdout, id);
        } else if (std.mem.eql(u8, method, "tools/call")) {
            try self.handleToolCall(stdout, id, params);
        } else {
            try sendError(stdout, id, -32601, "Method not found");
        }
    }

    fn sendInitializeResponse(self: *Server, stdout: *Io.Writer, id: ?std.json.Value, params: ?std.json.Value) !void {
        _ = self;
        const requested_version = if (params) |p| blk: {
            if (p == .object) {
                if (p.object.get("protocolVersion")) |v| {
                    if (v == .string) break :blk v.string;
                }
            }
            break :blk "2024-11-05";
        } else "2024-11-05";

        // We only advertise support for the version we implement.
        const protocol_version = if (std.mem.eql(u8, requested_version, "2024-11-05"))
            requested_version
        else
            "2024-11-05";

        const result = .{
            .protocolVersion = protocol_version,
            .capabilities = .{
                .tools = .{
                    .listChanged = false,
                },
            },
            .serverInfo = .{
                .name = "hunt",
                .version = "0.1.0",
            },
        };
        try sendResult(stdout, id, result);
    }

    fn sendToolsList(self: *Server, stdout: *Io.Writer, id: ?std.json.Value) !void {
        _ = self;
        const result = .{
            .tools = McpTools.tool_definitions,
        };
        try sendResult(stdout, id, result);
    }

    fn handleToolCall(self: *Server, stdout: *Io.Writer, id: ?std.json.Value, params: ?std.json.Value) !void {
        if (params == null or params.? != .object) {
            try sendError(stdout, id, -32602, "Invalid params: params object is required");
            return;
        }
        const obj = params.?.object;

        const name_val = obj.get("name");
        if (name_val == null or name_val.? != .string) {
            try sendError(stdout, id, -32602, "Invalid params: name is required");
            return;
        }
        const name = name_val.?.string;

        const arguments = obj.get("arguments") orelse {
            try sendError(stdout, id, -32602, "Invalid params: arguments is required");
            return;
        };
        if (arguments != .object) {
            try sendError(stdout, id, -32602, "Invalid params: arguments must be an object");
            return;
        }

        const meta = obj.get("_meta");
        const progress_token: ?std.json.Value = if (meta) |m| blk: {
            if (m == .object) {
                if (m.object.get("progressToken")) |t| break :blk t;
            }
            break :blk null;
        } else null;

        const options = self.makeDispatchOptions(progress_token, id) catch |err| {
            const err_text = try formatErrorJson(self.allocator, err, null);
            defer self.allocator.free(err_text);
            const result = .{
                .content = .{
                    .{ .type = "text", .text = err_text },
                },
                .isError = true,
            };
            try sendResult(stdout, id, result);
            return;
        };

        const tool_result = McpTools.dispatch(
            self.allocator,
            self.io,
            self.config_load,
            name,
            arguments,
            options,
        ) catch |err| {
            self.freeProgressContexts(&options);
            const err_text = try formatErrorJson(self.allocator, err, null);
            defer self.allocator.free(err_text);
            const result = .{
                .content = .{
                    .{ .type = "text", .text = err_text },
                },
                .isError = true,
            };
            try sendResult(stdout, id, result);
            return;
        };
        defer {
            tool_result.deinit(self.allocator);
            self.freeProgressContexts(&options);
        }

        switch (tool_result) {
            .success => |text| {
                const result = .{
                    .content = .{
                        .{ .type = "text", .text = text },
                    },
                    .isError = false,
                };
                try sendResult(stdout, id, result);
            },
            .failure => |info| {
                const err_text = try formatErrorInfoJson(self.allocator, info);
                defer self.allocator.free(err_text);
                const result = .{
                    .content = .{
                        .{ .type = "text", .text = err_text },
                    },
                    .isError = true,
                };
                try sendResult(stdout, id, result);
            },
        }
    }

    fn makeDispatchOptions(self: *Server, progress_token: ?std.json.Value, request_id: ?std.json.Value) !McpTools.DispatchOptions {
        if (progress_token == null or request_id == null) return .{};

        return .{
            .index_progress = .{
                .callback = progressForwarderCallback,
                .ctx = try self.createProgressContext(0, 12, progress_token.?, request_id.?),
            },
            .overview_progress = .{
                .callback = progressForwarderCallback,
                .ctx = try self.createProgressContext(9, 12, progress_token.?, request_id.?),
            },
        };
    }

    fn createProgressContext(
        self: *Server,
        stage_offset: usize,
        total_steps: usize,
        progress_token: std.json.Value,
        request_id: std.json.Value,
    ) !*ProgressContext {
        const ctx = try self.allocator.create(ProgressContext);
        ctx.* = .{
            .server = self,
            .stage_offset = stage_offset,
            .total_steps = total_steps,
            .progress_token = progress_token,
            .request_id = request_id,
        };
        return ctx;
    }

    fn freeProgressContexts(self: *Server, options: *const McpTools.DispatchOptions) void {
        if (options.index_progress.ctx) |ctx| self.allocator.destroy(@as(*ProgressContext, @ptrCast(@alignCast(ctx))));
        if (options.overview_progress.ctx) |ctx| self.allocator.destroy(@as(*ProgressContext, @ptrCast(@alignCast(ctx))));
    }

    fn sendProgress(
        self: *Server,
        request_id: std.json.Value,
        progress_token: std.json.Value,
        progress: usize,
        total: usize,
        message: []const u8,
    ) !void {
        _ = request_id;
        const stdout_file = Io.File.stdout();
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer: Io.File.Writer = .init(stdout_file, self.io, &stdout_buf);
        const stdout = &stdout_writer.interface;

        const notification = .{
            .jsonrpc = "2.0",
            .method = "notifications/progress",
            .params = .{
                .progressToken = progress_token,
                .progress = progress,
                .total = total,
                .message = message,
            },
        };
        try std.json.Stringify.value(notification, .{}, stdout);
        try stdout.writeByte('\n');
        try stdout_writer.flush();
    }
};

const ProgressContext = struct {
    server: *Server,
    stage_offset: usize,
    total_steps: usize,
    progress_token: std.json.Value,
    request_id: std.json.Value,
};

fn progressForwarderCallback(ctx: ?*anyopaque, event: Progress.Event) void {
    const self = @as(*ProgressContext, @ptrCast(@alignCast(ctx orelse return)));
    const progress = event.current_step + self.stage_offset;
    self.server.sendProgress(
        self.request_id,
        self.progress_token,
        @min(progress, self.total_steps),
        self.total_steps,
        event.label,
    ) catch {};
}

fn readLine(reader: *Io.File.Reader, allocator: std.mem.Allocator) !?[]const u8 {
    var line = std.ArrayList(u8).empty;
    errdefer line.deinit(allocator);
    while (true) {
        const byte = reader.interface.takeArray(1) catch |err| switch (err) {
            error.EndOfStream => {
                if (line.items.len == 0) return null;
                return try line.toOwnedSlice(allocator);
            },
            else => |e| return e,
        };
        if (byte[0] == '\n') {
            return try line.toOwnedSlice(allocator);
        }
        try line.append(allocator, byte[0]);
    }
}

fn sendResult(stdout: *Io.Writer, id: ?std.json.Value, result: anytype) !void {
    const response = .{
        .jsonrpc = "2.0",
        .id = id,
        .result = result,
    };
    try std.json.Stringify.value(response, .{}, stdout);
    try stdout.writeByte('\n');
}

fn sendError(stdout: *Io.Writer, id: ?std.json.Value, code: i64, message: []const u8) !void {
    const response = .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{
            .code = code,
            .message = message,
        },
    };
    try std.json.Stringify.value(response, .{}, stdout);
    try stdout.writeByte('\n');
}

fn formatErrorJson(allocator: std.mem.Allocator, err: anyerror, suggestion: ?[]const u8) ![]const u8 {
    const err_name = @errorName(err);
    var buf = Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    const writer = &buf.writer;

    try writer.writeAll("{");
    try writer.writeAll("\"error\":");
    try writeJsonString(writer, err_name);
    try writer.writeAll(",\"message\":");
    try writeJsonString(writer, errorMessage(err));
    if (suggestion) |s| {
        try writer.writeAll(",\"suggestion\":");
        try writeJsonString(writer, s);
    }
    try writer.writeAll("}");
    return try allocator.dupe(u8, buf.writer.buffer[0..buf.writer.end]);
}

fn formatErrorInfoJson(allocator: std.mem.Allocator, info: McpTools.ErrorInfo) ![]const u8 {
    var buf = Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    const writer = &buf.writer;

    try writer.writeAll("{");
    try writer.writeAll("\"error\":");
    try writeJsonString(writer, info.error_type);
    try writer.writeAll(",\"message\":");
    try writeJsonString(writer, info.message);
    if (info.suggestion) |s| {
        try writer.writeAll(",\"suggestion\":");
        try writeJsonString(writer, s);
    }
    try writer.writeAll("}");
    return try allocator.dupe(u8, buf.writer.buffer[0..buf.writer.end]);
}

fn writeJsonString(writer: *Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (c < 32) {
                try writer.print("\\u{x:0>4}", .{c});
            } else {
                try writer.writeByte(c);
            },
        }
    }
    try writer.writeByte('"');
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidArgument => "Invalid argument. Check required parameters and their values.",
        error.UnknownCommand => "Unknown command.",
        error.ObjectNotFound => "Object not found in the index.",
        error.EmptyFile => "The HPROF file is empty.",
        error.FileNotFound => "File not found.",
        error.NotDir => "Expected a directory but found a file.",
        error.IsDir => "Expected a file but found a directory.",
        error.AccessDenied => "Access denied.",
        error.TooManyObjects => "Too many objects to index.",
        error.SourceFingerprintMismatch => "The HPROF file has changed since indexing. Re-run analyze_heap_dump.",
        error.CacheMissing => "Overview cache not found. Run analyze_heap_dump for this heap dump first.",
        error.CacheCorrupt => "Overview cache is corrupt. Re-run analyze_heap_dump.",
        error.CacheVersionMismatch => "Overview cache version mismatch. Re-run analyze_heap_dump.",
        error.CacheFingerprintMismatch => "Overview cache is stale. Re-run analyze_heap_dump.",
        else => @errorName(err),
    };
}

test "sendError emits JSON-RPC error object" {
    const allocator = std.testing.allocator;
    var buf = Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    try sendError(&buf.writer, null, -32600, "Invalid Request");
    const output = buf.writer.buffer[0..buf.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, output, "\"error\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"failure\":") == null);
}

test "handleMessage rejects non-string jsonrpc" {
    const allocator = std.testing.allocator;
    var config_load: Config.LoadResult = .{};
    var server = Server.init(allocator, std.testing.io, &config_load);
    var buf = Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    try server.handleMessage(
        "{\"jsonrpc\":2.0,\"id\":1,\"method\":\"tools/list\"}",
        &buf.writer,
    );
    const output = buf.writer.buffer[0..buf.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, output, "\"error\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"code\":-32600") != null);
}

test "handleMessage initialize returns server info" {
    const allocator = std.testing.allocator;
    var config_load: Config.LoadResult = .{};
    var server = Server.init(allocator, std.testing.io, &config_load);
    const response = try callServer(allocator, &server, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\"}}");
    defer response.deinit();

    const root = response.value.object;
    try std.testing.expectEqualStrings("2.0", root.get("jsonrpc").?.string);
    try std.testing.expectEqual(@as(i64, 1), root.get("id").?.integer);

    const result = root.get("result").?.object;
    try std.testing.expectEqualStrings("2024-11-05", result.get("protocolVersion").?.string);

    const server_info = result.get("serverInfo").?.object;
    try std.testing.expectEqualStrings("hunt", server_info.get("name").?.string);
    try std.testing.expectEqualStrings("0.1.0", server_info.get("version").?.string);

    const capabilities = result.get("capabilities").?.object;
    try std.testing.expect(capabilities.get("tools").?.object.get("listChanged").?.bool == false);
}

test "handleMessage tools/list returns all tools" {
    const allocator = std.testing.allocator;
    var config_load: Config.LoadResult = .{};
    var server = Server.init(allocator, std.testing.io, &config_load);
    const response = try callServer(allocator, &server, "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/list\"}");
    defer response.deinit();

    const root = response.value.object;
    try std.testing.expectEqualStrings("2.0", root.get("jsonrpc").?.string);
    try std.testing.expectEqual(@as(i64, 42), root.get("id").?.integer);

    const tools = root.get("result").?.object.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 12), tools.items.len);

    const expected_names = [_][]const u8{
        "analyze_heap_dump",
        "heap_info",
        "heap_histogram",
        "heap_classes",
        "find_objects",
        "sample_objects",
        "get_object",
        "refs_from",
        "refs_to",
        "list_threads",
        "find_roots",
        "reference_tree",
    };
    for (expected_names, tools.items) |expected, tool| {
        try std.testing.expectEqualStrings(expected, tool.object.get("name").?.string);
    }
}

test "handleMessage unknown method returns -32601" {
    const allocator = std.testing.allocator;
    var config_load: Config.LoadResult = .{};
    var server = Server.init(allocator, std.testing.io, &config_load);
    const response = try callServer(allocator, &server, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"unknown/method\"}");
    defer response.deinit();

    const err = response.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32601), err.get("code").?.integer);
    try std.testing.expectEqual(@as(i64, 7), response.value.object.get("id").?.integer);
}

test "handleMessage missing method returns -32600" {
    const allocator = std.testing.allocator;
    var config_load: Config.LoadResult = .{};
    var server = Server.init(allocator, std.testing.io, &config_load);
    const response = try callServer(allocator, &server, "{\"jsonrpc\":\"2.0\",\"id\":8}");
    defer response.deinit();

    const err = response.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32600), err.get("code").?.integer);
}

test "handleMessage malformed json returns -32700" {
    const allocator = std.testing.allocator;
    var config_load: Config.LoadResult = .{};
    var server = Server.init(allocator, std.testing.io, &config_load);
    const response = try callServer(allocator, &server, "{not json}");
    defer response.deinit();

    const err = response.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32700), err.get("code").?.integer);
}

test "handleMessage tools/call missing arguments returns -32602" {
    const allocator = std.testing.allocator;
    var config_load: Config.LoadResult = .{};
    var server = Server.init(allocator, std.testing.io, &config_load);
    const response = try callServer(allocator, &server, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"heap_info\"}}");
    defer response.deinit();

    const err = response.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32602), err.get("code").?.integer);
}

test "handleMessage tools/call unknown tool returns isError true" {
    const allocator = std.testing.allocator;
    var config_load: Config.LoadResult = .{};
    var server = Server.init(allocator, std.testing.io, &config_load);
    const response = try callServer(allocator, &server, "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"no_such_tool\",\"arguments\":{}}}");
    defer response.deinit();

    const result = response.value.object.get("result").?.object;
    try std.testing.expect(result.get("isError").?.bool == true);
    try std.testing.expectEqualStrings("text", result.get("content").?.array.items[0].object.get("type").?.string);
}

fn callServer(
    allocator: std.mem.Allocator,
    server: *Server,
    request: []const u8,
) !std.json.Parsed(std.json.Value) {
    var buf = Io.Writer.Allocating.init(allocator);
    defer buf.deinit();
    try server.handleMessage(request, &buf.writer);
    const output = buf.writer.buffer[0..buf.writer.end];
    return try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
}

const log = std.log.scoped(.mcp);
