const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const APP_VERSION = "0.1.0";
const CATALOG_URL = "https://raw.githubusercontent.com/BANSAFAn/i10n-downloadform/main/index.json";
const ALLOWED_PREFIX_1 = "https://raw.githubusercontent.com/BANSAFAn/i10n-downloadform/";
const ALLOWED_PREFIX_2 = "https://github.com/BANSAFAn/i10n-downloadform/";
const EMBEDDED_UI = @embedFile("ui.html");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len >= 2) {
        const cmd = args[1];
        if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
            std.debug.print(
                \\MeowLab i10n Portable Installer v{s} (Zig)
                \\Usage:
                \\  meowlab-i10n                                   Launch portable GUI (no installer)
                \\  meowlab-i10n detect                            List detected Minecraft folders
                \\  meowlab-i10n install-local <file> <dir> <sub?> Install local translation pack
                \\
            , .{APP_VERSION});
            return;
        }
        if (std.mem.eql(u8, cmd, "detect")) {
            const dirs = try detectMinecraftDirs(arena, io, init.environ_map);
            for (dirs) |d| std.debug.print("{s}\n", .{d});
            return;
        }
        if (std.mem.eql(u8, cmd, "install-local") and args.len >= 4) {
            const src_path = args[2];
            const game_dir = args[3];
            const sub = if (args.len >= 5) args[4] else "resourcepacks";
            const file_bytes = try Io.Dir.cwd().readFileAlloc(io, src_path, gpa, .limited(64 * 1024 * 1024));
            defer gpa.free(file_bytes);
            const base = std.fs.path.basename(src_path);
            const dest = try installBytes(arena, io, game_dir, sub, base, file_bytes);
            std.debug.print("Installed to: {s}\n", .{dest});
            return;
        }
    }

    // Portable GUI Mode: bind strictly to 127.0.0.1 on an ephemeral free port
    const listen_addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try listen_addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    const port = server.socket.address.getPort();
    const ui_url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/", .{port});
    std.debug.print("MeowLab i10n v{s} running at {s}\nPress Ctrl+C to stop.\n", .{ APP_VERSION, ui_url });

    openBrowser(io, ui_url);

    while (true) {
        var stream = server.accept(io) catch continue;
        handleConnection(gpa, io, init.environ_map, &stream) catch |err| {
            std.debug.print("request error: {s}\n", .{@errorName(err)});
        };
        stream.close(io);
    }
}

fn openBrowser(io: Io, url: []const u8) void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .windows => &.{ "cmd", "/c", "start", "", url },
        .macos => &.{ "open", url },
        else => &.{ "xdg-open", url },
    };
    _ = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {};
}

fn handleConnection(
    gpa: std.mem.Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    stream: *Io.net.Stream,
) !void {
    var in_buf: [16 * 1024]u8 = undefined;
    var out_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &in_buf);
    var writer = stream.writer(io, &out_buf);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);

    var req = http_server.receiveHead() catch return;

    var req_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer req_arena_state.deinit();
    const alloc = req_arena_state.allocator();

    const target = req.head.target;

    if (std.mem.eql(u8, target, "/") or std.mem.startsWith(u8, target, "/?")) {
        try req.respond(EMBEDDED_UI, .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
        });
        return;
    }

    if (std.mem.eql(u8, target, "/api/info")) {
        const dirs = try detectMinecraftDirs(alloc, io, env);
        var out: Io.Writer.Allocating = .init(alloc);
        try out.writer.writeAll("{\"version\":\"");
        try out.writer.writeAll(APP_VERSION);
        try out.writer.writeAll("\",\"os\":\"");
        try out.writer.writeAll(@tagName(builtin.os.tag));
        try out.writer.writeAll("\",\"detected\":[");
        for (dirs, 0..) |d, idx| {
            if (idx > 0) try out.writer.writeByte(',');
            try writeJsonString(&out.writer, d);
        }
        try out.writer.writeAll("]}");
        try req.respond(out.written(), .{
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json; charset=utf-8" }},
        });
        return;
    }

    if (std.mem.eql(u8, target, "/api/catalog")) {
        const body = fetchUrl(alloc, io, CATALOG_URL) catch |err| {
            const msg = try std.fmt.allocPrint(alloc, "{{\"error\":\"{s}\"}}", .{@errorName(err)});
            try req.respond(msg, .{
                .status = .bad_gateway,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json; charset=utf-8" }},
            });
            return;
        };
        try req.respond(body, .{
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json; charset=utf-8" }},
        });
        return;
    }

    if (std.mem.eql(u8, target, "/api/install-remote") and req.head.method == .POST) {
        const dl_url = getHeader(&req, "x-download-url") orelse return sendText(&req, .bad_request, "Missing X-Download-Url");
        const raw_name = getHeader(&req, "x-file-name") orelse return sendText(&req, .bad_request, "Missing X-File-Name");
        const raw_dir = getHeader(&req, "x-game-dir") orelse return sendText(&req, .bad_request, "Missing X-Game-Dir");
        const sub = getHeader(&req, "x-install-target") orelse "resourcepacks";

        if (!std.mem.startsWith(u8, dl_url, ALLOWED_PREFIX_1) and !std.mem.startsWith(u8, dl_url, ALLOWED_PREFIX_2)) {
            return sendText(&req, .forbidden, "Download URL must belong to BANSAFAn/i10n-downloadform");
        }

        const game_dir = try percentDecode(alloc, raw_dir);
        const file_name = try percentDecode(alloc, raw_name);
        const bytes = fetchUrl(alloc, io, dl_url) catch |err| {
            const msg = try std.fmt.allocPrint(alloc, "Download failed: {s}", .{@errorName(err)});
            return sendText(&req, .bad_gateway, msg);
        };
        const dest = installBytes(alloc, io, game_dir, sub, file_name, bytes) catch |err| {
            const msg = try std.fmt.allocPrint(alloc, "Install failed: {s}", .{@errorName(err)});
            return sendText(&req, .bad_request, msg);
        };
        const msg = try std.fmt.allocPrint(alloc, "Installed: {s}", .{dest});
        return sendText(&req, .ok, msg);
    }

    if (std.mem.eql(u8, target, "/api/install-local") and req.head.method == .POST) {
        const raw_name = getHeader(&req, "x-file-name") orelse return sendText(&req, .bad_request, "Missing X-File-Name");
        const raw_dir = getHeader(&req, "x-game-dir") orelse return sendText(&req, .bad_request, "Missing X-Game-Dir");
        const sub = getHeader(&req, "x-install-target") orelse "resourcepacks";

        const game_dir = try percentDecode(alloc, raw_dir);
        const file_name = try percentDecode(alloc, raw_name);

        var body_buf: [8192]u8 = undefined;
        const body_reader = req.readerExpectNone(&body_buf);
        const bytes = body_reader.allocRemaining(alloc, .limited(64 * 1024 * 1024)) catch {
            return sendText(&req, .payload_too_large, "File too large (max 64 MB)");
        };
        const dest = installBytes(alloc, io, game_dir, sub, file_name, bytes) catch |err| {
            const msg = try std.fmt.allocPrint(alloc, "Install failed: {s}", .{@errorName(err)});
            return sendText(&req, .bad_request, msg);
        };
        const msg = try std.fmt.allocPrint(alloc, "Installed locally: {s}", .{dest});
        return sendText(&req, .ok, msg);
    }

    try sendText(&req, .not_found, "Not found");
}

fn sendText(req: *std.http.Server.Request, status: std.http.Status, msg: []const u8) !void {
    try req.respond(msg, .{
        .status = status,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
    });
}

fn getHeader(req: *std.http.Server.Request, wanted: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, wanted)) return h.value;
    }
    return null;
}

fn fetchUrl(alloc: std.mem.Allocator, io: Io, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    var out: Io.Writer.Allocating = .init(alloc);
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &out.writer,
    });
    if (res.status != .ok) return error.HttpError;
    return out.toOwnedSlice();
}

fn isAllowedSubdir(sub: []const u8) bool {
    const allowed = [_][]const u8{ "resourcepacks", "shaderpacks", "datapacks", "mods", "config" };
    for (allowed) |a| {
        if (std.mem.eql(u8, sub, a)) return true;
    }
    return false;
}

fn sanitizeFileName(alloc: std.mem.Allocator, raw: []const u8) ![]u8 {
    const base = std.fs.path.basename(raw);
    if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) {
        return error.InvalidFileName;
    }
    var buf: std.ArrayList(u8) = .empty;
    for (base) |c| {
        if (c == '/' or c == '\\' or c == ':' or c == '*' or c == '?' or c == '"' or c == '<' or c == '>' or c == '|' or c < 0x20) {
            try buf.append(alloc, '_');
        } else {
            try buf.append(alloc, c);
        }
    }
    return buf.toOwnedSlice(alloc);
}

fn installBytes(
    alloc: std.mem.Allocator,
    io: Io,
    game_dir: []const u8,
    sub_dir: []const u8,
    raw_file_name: []const u8,
    bytes: []const u8,
) ![]u8 {
    if (game_dir.len == 0) return error.EmptyGameDir;
    if (!isAllowedSubdir(sub_dir)) return error.InvalidInstallTarget;
    const safe_name = try sanitizeFileName(alloc, raw_file_name);

    const target_folder = try std.fs.path.join(alloc, &.{ game_dir, sub_dir });
    try Io.Dir.cwd().createDirPath(io, target_folder);

    const dest_path = try std.fs.path.join(alloc, &.{ target_folder, safe_name });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dest_path, .data = bytes });
    return dest_path;
}

fn detectMinecraftDirs(
    alloc: std.mem.Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    const candidates: []const []const u8 = switch (builtin.os.tag) {
        .windows => blk: {
            var tmp: std.ArrayList([]const u8) = .empty;
            if (env.get("APPDATA")) |appdata| {
                try tmp.append(alloc, try std.fs.path.join(alloc, &.{ appdata, ".minecraft" }));
                try tmp.append(alloc, try std.fs.path.join(alloc, &.{ appdata, "PrismLauncher", "instances" }));
                try tmp.append(alloc, try std.fs.path.join(alloc, &.{ appdata, "MultiMC", "instances" }));
                try tmp.append(alloc, try std.fs.path.join(alloc, &.{ appdata, "xmcl" }));
                try tmp.append(alloc, try std.fs.path.join(alloc, &.{ appdata, "ModrinthApp", "profiles" }));
            }
            break :blk try tmp.toOwnedSlice(alloc);
        },
        .macos => blk: {
            var tmp: std.ArrayList([]const u8) = .empty;
            if (env.get("HOME")) |home| {
                try tmp.append(alloc, try std.fs.path.join(alloc, &.{ home, "Library", "Application Support", "minecraft" }));
                try tmp.append(alloc, try std.fs.path.join(alloc, &.{ home, "Library", "Application Support", "PrismLauncher", "instances" }));
                try tmp.append(alloc, try std.fs.path.join(alloc, &.{ home, "Library", "Application Support", "ModrinthApp", "profiles" }));
            }
            break :blk try tmp.toOwnedSlice(alloc);
        },
        else => blk: {
            var tmp: std.ArrayList([]const u8) = .empty;
            if (env.get("HOME")) |home| {
                try tmp.append(alloc, try std.fs.path.join(alloc, &.{ home, ".minecraft" }));
                try tmp.append(alloc, try std.fs.path.join(alloc, &.{ home, ".local", "share", "PrismLauncher", "instances" }));
                try tmp.append(alloc, try std.fs.path.join(alloc, &.{ home, ".local", "share", "MultiMC", "instances" }));
                try tmp.append(alloc, try std.fs.path.join(alloc, &.{ home, ".config", "ModrinthApp", "profiles" }));
            }
            break :blk try tmp.toOwnedSlice(alloc);
        },
    };

    for (candidates) |c| {
        if (Io.Dir.cwd().access(io, c, .{})) |_| {
            try list.append(alloc, try alloc.dupe(u8, c));
        } else |_| {}
    }
    return list.toOwnedSlice(alloc);
}

fn percentDecode(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            if (std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16)) |byte| {
                try out.append(alloc, byte);
                i += 3;
                continue;
            } else |_| {}
        }
        try out.append(alloc, input[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

test "sanitizeFileName prevents path traversal" {
    const alloc = std.testing.allocator;
    const clean = try sanitizeFileName(alloc, "../../evil:pack*.zip");
    defer alloc.free(clean);
    try std.testing.expectEqualStrings("evil_pack_.zip", clean);
}

test "percentDecode handles UTF-8 paths" {
    const alloc = std.testing.allocator;
    const dec = try percentDecode(alloc, "C%3A%5CUsers%5Ctest");
    defer alloc.free(dec);
    try std.testing.expectEqualStrings("C:\\Users\\test", dec);
}
