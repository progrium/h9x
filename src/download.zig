//! Downloads on the host: the bootstrap's Alpine minirootfs, Wolfi's
//! signing key, and Railpack's release (design/prototype.md,
//! "Compatibility": the host needs no `curl`).
//!
//! Without a proxy this is `std.http.Client`. Behind an HTTPS proxy it's
//! a small client of its own, since std's sends a CONNECT for an
//! `https://` URL and then speaks plain HTTP down the tunnel: a CONNECT,
//! TLS to the origin with the host's CA bundle and `SSL_CERT_FILE`, then
//! one HTTP/1.0 GET, following redirects. HTTP/1.0 means no chunked
//! bodies: the body runs to the end of the connection, checked against
//! Content-Length when the server sends one.

const std = @import("std");
const Io = std.Io;

pub const Error = error{
    /// Not a 2xx after redirects; `why` says what the server said.
    Status,
    BadUrl,
    BadResponse,
    TooManyRedirects,
    /// The body was shorter than its Content-Length.
    Truncated,
    OutOfMemory,
} || anyerror;

pub const Options = struct {
    /// `HTTPS_PROXY`, as `http://HOST:PORT`.
    https_proxy: ?[]const u8 = null,
    /// `SSL_CERT_FILE`, added to the host's bundle.
    ca_file: ?[]const u8 = null,
    /// Hosts that skip the proxy (`NO_PROXY`), comma-separated.
    no_proxy: []const u8 = "",
};

/// Options from the environment: HTTPS_PROXY, SSL_CERT_FILE, and NO_PROXY.
pub fn optionsFrom(env: *const std.process.Environ.Map) Options {
    return .{
        .https_proxy = nonEmpty(env.get("HTTPS_PROXY") orelse env.get("https_proxy")),
        .ca_file = nonEmpty(env.get("SSL_CERT_FILE")),
        .no_proxy = env.get("NO_PROXY") orelse env.get("no_proxy") orelse "",
    };
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len > 0) v else null;
}

/// Downloads `url` into `dest`, through `dest.tmp`, so an interrupted
/// download leaves nothing at `dest`. `why` says what went wrong.
pub fn toFile(gpa: std.mem.Allocator, io: Io, url: []const u8, dest: []const u8, o: Options, why: *[]const u8) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(dest)) |d| try cwd.createDirPath(io, d);
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{dest});
    {
        var file = try cwd.createFile(io, tmp, .{});
        defer file.close(io);
        var buf: [64 << 10]u8 = undefined;
        var fw = file.writer(io, &buf);
        get(gpa, io, url, o, &fw.interface, why) catch |e| {
            cwd.deleteFile(io, tmp) catch {};
            return e;
        };
        try fw.interface.flush();
    }
    try Io.Dir.rename(cwd, tmp, cwd, dest, io);
}

/// Writes the body at `url` to `w`.
pub fn get(gpa: std.mem.Allocator, io: Io, url: []const u8, o: Options, w: *Io.Writer, why: *[]const u8) Error!void {
    why.* = "";
    const uri = std.Uri.parse(url) catch return error.BadUrl;
    const host = uri.host orelse return error.BadUrl;
    var hbuf: [256]u8 = undefined;
    const h = host.toRaw(&hbuf) catch return error.BadUrl;
    if (o.https_proxy) |p| if (!bypass(o.no_proxy, h)) return proxied(gpa, io, url, p, o, w, why);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    if (o.ca_file) |f| {
        client.now = Io.Clock.real.now(io);
        try client.ca_bundle.rescan(gpa, io, client.now.?);
        client.ca_bundle.addCertsFromFilePath(gpa, io, client.now.?, Io.Dir.cwd(), f) catch {};
    }
    const r = try client.fetch(.{ .location = .{ .url = url }, .response_writer = w });
    if (r.status.class() != .success) {
        why.* = r.status.phrase() orelse "unexpected status";
        return error.Status;
    }
}

/// Whether NO_PROXY's list names `host`: an exact name, or a suffix
/// given as `.example.com` or `example.com`.
fn bypass(no_proxy: []const u8, host: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, no_proxy, ", ");
    while (it.next()) |raw| {
        const e = std.mem.trimStart(u8, raw, "*");
        if (e.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(e, host)) return true;
        const suffix = std.mem.trimStart(u8, e, ".");
        if (host.len > suffix.len and std.ascii.endsWithIgnoreCase(host, suffix) and host[host.len - suffix.len - 1] == '.') return true;
    }
    return false;
}

const max_redirects = 8;

fn proxied(gpa: std.mem.Allocator, io: Io, first_url: []const u8, proxy: []const u8, o: Options, w: *Io.Writer, why: *[]const u8) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(gpa);
    const now = Io.Clock.real.now(io);
    try bundle.rescan(gpa, io, now);
    if (o.ca_file) |f| bundle.addCertsFromFilePath(gpa, io, now, Io.Dir.cwd(), f) catch {};
    var lock: Io.RwLock = .init;

    const pu = std.Uri.parse(if (std.mem.indexOf(u8, proxy, "://") == null) try std.fmt.allocPrint(arena, "http://{s}", .{proxy}) else proxy) catch return error.BadUrl;
    var pbuf: [256]u8 = undefined;
    const phost = (pu.host orelse return error.BadUrl).toRaw(&pbuf) catch return error.BadUrl;
    const pport = pu.port orelse 80;

    var url = first_url;
    var hops: usize = 0;
    while (true) : (hops += 1) {
        if (hops > max_redirects) return error.TooManyRedirects;
        const uri = std.Uri.parse(url) catch return error.BadUrl;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.BadUrl;
        var hbuf: [256]u8 = undefined;
        const host = (uri.host orelse return error.BadUrl).toRaw(&hbuf) catch return error.BadUrl;
        const port = uri.port orelse 443;
        var target: Io.Writer.Allocating = .init(arena);
        uri.writeToStream(&target.writer, .{ .path = true, .query = true }) catch return error.OutOfMemory;
        const path = if (target.written().len == 0) "/" else target.written();

        const hn = std.Io.net.HostName.init(phost) catch return error.BadUrl;
        var stream = try hn.connect(io, pport, .{ .mode = .stream });
        defer stream.close(io);
        var sr_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
        var sw_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
        var sr = stream.reader(io, &sr_buf);
        var sw = stream.writer(io, &sw_buf);

        // The tunnel.
        try sw.interface.print("CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\n\r\n", .{ host, port, host, port });
        try sw.interface.flush();
        const head = try readHead(arena, &sr.interface);
        const st = statusOf(head) orelse return error.BadResponse;
        if (st / 100 != 2) {
            why.* = try std.fmt.allocPrint(arena, "proxy: {s}", .{firstLine(head)});
            why.* = try gpa.dupe(u8, why.*);
            return error.Status;
        }

        // TLS to the origin, then the request.
        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&entropy);
        var tr_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
        var tw_buf: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
        var tls = try std.crypto.tls.Client.init(&sr.interface, &sw.interface, .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = .{ .gpa = gpa, .io = io, .lock = &lock, .bundle = &bundle } },
            .read_buffer = &tr_buf,
            .write_buffer = &tw_buf,
            .entropy = &entropy,
            .realtime_now = now,
            // HTTP/1.0 ends the body with the connection; Content-Length,
            // when sent, is checked below.
            .allow_truncation_attacks = true,
        });
        try tls.writer.print("GET {s} HTTP/1.0\r\nHost: {s}\r\nUser-Agent: h9x\r\nAccept: */*\r\nConnection: close\r\n\r\n", .{ path, host });
        try tls.writer.flush();
        try sw.interface.flush();

        const rhead = try readHead(arena, &tls.reader);
        const status = statusOf(rhead) orelse return error.BadResponse;
        if (status / 100 == 3) {
            const loc = header(rhead, "location") orelse return error.BadResponse;
            url = try resolve(arena, uri, loc);
            continue;
        }
        if (status / 100 != 2) {
            why.* = try gpa.dupe(u8, firstLine(rhead));
            return error.Status;
        }
        const want: ?u64 = if (header(rhead, "content-length")) |cl| std.fmt.parseInt(u64, cl, 10) catch null else null;
        var n: u64 = 0;
        while (true) {
            const got = tls.reader.stream(w, .unlimited) catch |e| switch (e) {
                error.EndOfStream => break,
                error.ReadFailed => {
                    // A server that closes without close_notify, or a reset
                    // after the whole body: fine if the length is right.
                    if (want) |l| if (n == l) break;
                    return error.Truncated;
                },
                error.WriteFailed => return error.WriteFailed,
            };
            n += got;
            if (want) |l| if (n >= l) break;
        }
        if (want) |l| if (n != l) return error.Truncated;
        return;
    }
}

/// Reads up to the blank line after the headers.
fn readHead(arena: std.mem.Allocator, r: *Io.Reader) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    while (true) {
        const b = r.takeByte() catch return error.BadResponse;
        try out.append(arena, b);
        if (std.mem.endsWith(u8, out.items, "\r\n\r\n")) return out.items;
        if (out.items.len > 64 << 10) return error.BadResponse;
    }
}

fn firstLine(head: []const u8) []const u8 {
    return head[0 .. std.mem.indexOf(u8, head, "\r\n") orelse head.len];
}

fn statusOf(head: []const u8) ?u16 {
    var it = std.mem.tokenizeScalar(u8, firstLine(head), ' ');
    _ = it.next() orelse return null;
    return std.fmt.parseInt(u16, it.next() orelse return null, 10) catch null;
}

fn header(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    _ = lines.next();
    while (lines.next()) |l| {
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, l[0..colon], " "), name)) return std.mem.trim(u8, l[colon + 1 ..], " \t");
    }
    return null;
}

/// A Location against the URL it came from.
fn resolve(arena: std.mem.Allocator, base: std.Uri, loc: []const u8) error{ OutOfMemory, BadUrl }![]const u8 {
    if (std.mem.indexOf(u8, loc, "://") != null) return arena.dupe(u8, loc);
    var buf: [256]u8 = undefined;
    const host = (base.host orelse return error.BadUrl).toRaw(&buf) catch return error.BadUrl;
    if (std.mem.startsWith(u8, loc, "//")) return std.fmt.allocPrint(arena, "{s}:{s}", .{ base.scheme, loc });
    if (std.mem.startsWith(u8, loc, "/")) return std.fmt.allocPrint(arena, "{s}://{s}{s}", .{ base.scheme, host, loc });
    return error.BadUrl;
}

test bypass {
    try std.testing.expect(bypass("localhost,.example.com", "a.example.com"));
    try std.testing.expect(bypass("pypi.org", "pypi.org"));
    try std.testing.expect(!bypass("pypi.org", "notpypi.org"));
    try std.testing.expect(!bypass("", "github.com"));
}

test header {
    const h = "HTTP/1.1 302 Found\r\nLocation: https://x/y\r\nContent-Length: 0\r\n\r\n";
    try std.testing.expectEqual(@as(?u16, 302), statusOf(h));
    try std.testing.expectEqualStrings("https://x/y", header(h, "location").?);
}
