const std = @import("std");

pub const Request = struct {
    allocator: std.mem.Allocator,
    raw: std.http.Server.Request,
    method: std.http.Method,
    url: std.Uri,

    pub fn init(allocator: std.mem.Allocator, raw: std.http.Server.Request) !Request {
        return .{
            .allocator = allocator,
            .raw = raw,
            .method = raw.head.method,
            .url = try std.Uri.parseWithoutScheme(raw.head.target),
        };
    }

    /// Returns the value of the given header or null if it doesn't exist.
    pub fn getHeader(self: *Request, name: []const u8) ?[]const u8 {
        var it = self.raw.iterateHeaders();

        while (it.next()) |header| {
            if (std.mem.eql(u8, header.name, name)) return header.value;
        }

        return null;
    }

    /// Tries to match the request path against the given pattern and returns
    /// the parsed parameters.
    pub fn match(self: *Request, pattern: []const u8) ?Params {
        return Params.match(pattern, self.url.path);
    }

    /// Reads the request body as JSON.
    pub fn readJson(self: *Request, comptime T: type) !T {
        var reader = std.json.reader(self.allocator, try self.raw.reader());

        return std.json.parseFromTokenSourceLeaky(
            T,
            self.allocator,
            &reader,
            .{ .ignore_unknown_fields = true },
        );
    }
};

pub const Params = struct {
    matches: [16][]const u8 = undefined,
    len: usize = 0,

    pub fn match(pattern: []const u8, path: []const u8) ?Params {
        var res = Params{};
        var pattern_parts = std.mem.tokenizeScalar(u8, pattern, '/');
        var path_parts = std.mem.tokenizeScalar(u8, path, '/');

        while (true) {
            const pat = pattern_parts.next() orelse return if (pattern[pattern.len - 1] == '*' or path_parts.next() == null) res else null;
            const pth = path_parts.next() orelse return null;
            const dynamic = pat[0] == ':' or pat[0] == '*';

            if (std.mem.indexOfScalar(u8, pat, '.')) |i| {
                const j = (if (dynamic) std.mem.lastIndexOfScalar(u8, pth, '.') else std.mem.indexOfScalar(u8, pth, '.')) orelse return null;

                if (match(pat[i + 1 ..], pth[j + 1 ..])) |ch| {
                    for (ch.matches, res.len..) |s, l| res.matches[l] = s;
                    res.len += ch.len;
                } else return null;
            }

            if (!dynamic and !std.mem.eql(u8, pat, pth)) return null;

            if (pat[0] == ':') {
                res.matches[res.len] = pth;
                res.len += 1;
            }
        }
    }

    pub fn get(self: *const Params, index: usize, comptime T: type) !T {
        const s = if (index < self.len) self.matches[index] else return error.NoMatch;

        return switch (@typeInfo(T)) {
            .Int => std.fmt.parseInt(T, s, 10),
            else => s,
        };
    }
};
