const std = @import("std");

const Allocator = std.mem.Allocator;
const REGISTRY_URL = "https://zub.javanile.org/packages.json";
const DEFAULT_ZIG_VERSION = "master";

const Package = struct {
    title: []const u8,
    description: ?[]const u8 = null,
    url: []const u8,
    keywords: ?[]const []const u8 = null,
    categories: ?[]const []const u8 = null,
};

const PackageRef = struct {
    owner: []const u8,
    repo: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    if (std.mem.eql(u8, args[1], "install")) {
        if (args.len < 3) {
            std.log.err("missing package name", .{});
            try printUsage();
            return error.InvalidArguments;
        }
        try installPackage(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, args[1], "search")) {
        if (args.len < 3) {
            std.log.err("missing search query", .{});
            try printUsage();
            return error.InvalidArguments;
        }
        try searchPackages(allocator, args[2]);
        return;
    }

    if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "help")) {
        try printUsage();
        return;
    }

    std.log.err("unknown command: {s}", .{args[1]});
    try printUsage();
    return error.InvalidArguments;
}

fn printUsage() !void {
    std.debug.print(
        \\zub - Zig binary installer
        \\
        \\Usage:
        \\  zub install <package>
        \\  zub search <query>
        \\
        \\Registry:
        \\  {s}
        \\
    , .{REGISTRY_URL});
}

fn installPackage(allocator: Allocator, package_name: []const u8) !void {
    const home = try getEnvOwned(allocator, "HOME");
    defer allocator.free(home);

    const local_bin_dir = try std.fs.path.join(allocator, &.{ home, ".local", "bin" });
    defer allocator.free(local_bin_dir);
    try ensureDirAbsolute(local_bin_dir);

    const cache_src_dir = try std.fs.path.join(allocator, &.{ home, ".cache", "zub", "src" });
    defer allocator.free(cache_src_dir);
    try ensureDirAbsolute(cache_src_dir);

    const packages = try loadPackages(allocator);
    defer freePackages(allocator, packages);

    const pkg = findPackage(packages, package_name) orelse {
        std.log.err("package not found in registry: {s}", .{package_name});
        return error.PackageNotFound;
    };

    const pkg_ref = try packageRefFromUrl(pkg.url);
    const repo_url = try std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}.git", .{ pkg_ref.owner, pkg_ref.repo });
    defer allocator.free(repo_url);

    const repo_cache_dir = try std.fs.path.join(allocator, &.{ cache_src_dir, pkg_ref.owner, pkg_ref.repo });
    defer allocator.free(repo_cache_dir);

    try cloneOrUpdateRepo(allocator, repo_url, repo_cache_dir);

    const required_zig = try detectRequiredZigVersion(allocator, repo_cache_dir);
    defer allocator.free(required_zig);

    const zvm = try ensureZvmAvailable(allocator);
    defer allocator.free(zvm);

    std.debug.print("using Zig {s}\n", .{required_zig});
    try runCommand(allocator, null, &.{ zvm, "install", required_zig });
    try runCommand(allocator, repo_cache_dir, &.{ zvm, "run", required_zig, "build", "-Doptimize=ReleaseSafe" });

    const built_binary = try findBuiltBinary(allocator, repo_cache_dir, package_name);
    defer allocator.free(built_binary);

    const install_target = try std.fs.path.join(allocator, &.{ local_bin_dir, package_name });
    defer allocator.free(install_target);

    try copyFileAbsolute(built_binary, install_target);
    std.debug.print("installed {s} -> {s}\n", .{ package_name, install_target });
}

fn searchPackages(allocator: Allocator, query: []const u8) !void {
    const packages = try loadPackages(allocator);
    defer freePackages(allocator, packages);

    var match_count: usize = 0;
    for (packages) |pkg| {
        if (!packageMatchesQuery(pkg, query)) continue;
        match_count += 1;

        std.debug.print("{s}\n", .{pkg.title});
        if (pkg.description) |description| {
            std.debug.print("  {s}\n", .{description});
        }
        std.debug.print("  {s}\n\n", .{pkg.url});
    }

    if (match_count == 0) {
        std.debug.print("no packages found for query: {s}\n", .{query});
    } else {
        std.debug.print("{d} package(s) matched\n", .{match_count});
    }
}

fn getEnvOwned(allocator: Allocator, name: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.log.err("missing environment variable: {s}", .{name});
            return err;
        },
        else => return err,
    };
}

fn ensureDirAbsolute(path: []const u8) !void {
    try std.fs.cwd().makePath(path);
}

fn fetchUrl(allocator: Allocator, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    var response_writer = std.Io.Writer.Allocating.fromArrayList(allocator, &body);
    defer response_writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .uri = uri },
        .response_writer = &response_writer.writer,
    });

    if (result.status != .ok) {
        std.log.err("download failed for {s}: {s}", .{ url, @tagName(result.status) });
        return error.DownloadFailed;
    }

    var owned = response_writer.toArrayList();
    return owned.toOwnedSlice(allocator);
}

fn loadPackages(allocator: Allocator) ![]Package {
    const packages_json = try fetchUrl(allocator, REGISTRY_URL);
    defer allocator.free(packages_json);
    return parsePackages(allocator, packages_json);
}

fn freePackages(allocator: Allocator, packages: []Package) void {
    for (packages) |pkg| {
        allocator.free(pkg.title);
        allocator.free(pkg.url);
        if (pkg.description) |description| allocator.free(description);
        if (pkg.keywords) |keywords| {
            for (keywords) |keyword| allocator.free(keyword);
            allocator.free(keywords);
        }
        if (pkg.categories) |categories| {
            for (categories) |category| allocator.free(category);
            allocator.free(categories);
        }
    }
    allocator.free(packages);
}

fn parsePackages(allocator: Allocator, json_bytes: []const u8) ![]Package {
    const Parsed = struct {
        title: []const u8,
        description: ?[]const u8 = null,
        url: []const u8,
        keywords: ?[]const ?[]const u8 = null,
        categories: ?[]const []const u8 = null,
    };

    var parsed = try std.json.parseFromSlice([]Parsed, allocator, json_bytes, .{});
    defer parsed.deinit();

    var packages = try allocator.alloc(Package, parsed.value.len);
    for (parsed.value, 0..) |pkg, i| {
        var keywords_owned: ?[][]const u8 = null;
        if (pkg.keywords) |keywords| {
            var list = try allocator.alloc([]const u8, keywords.len);
            var count: usize = 0;
            for (keywords) |keyword_opt| {
                if (keyword_opt) |keyword| {
                    list[count] = try allocator.dupe(u8, keyword);
                    count += 1;
                }
            }
            keywords_owned = list[0..count];
        }

        var categories_owned: ?[][]const u8 = null;
        if (pkg.categories) |categories| {
            var list = try allocator.alloc([]const u8, categories.len);
            for (categories, 0..) |category, index| {
                list[index] = try allocator.dupe(u8, category);
            }
            categories_owned = list;
        }

        packages[i] = .{
            .title = try allocator.dupe(u8, pkg.title),
            .description = if (pkg.description) |description| try allocator.dupe(u8, description) else null,
            .url = try allocator.dupe(u8, pkg.url),
            .keywords = keywords_owned,
            .categories = categories_owned,
        };
    }
    return packages;
}

fn findPackage(packages: []const Package, name: []const u8) ?Package {
    for (packages) |pkg| {
        if (std.mem.eql(u8, pkg.title, name)) return pkg;
    }
    return null;
}

fn packageMatchesQuery(pkg: Package, query: []const u8) bool {
    if (containsIgnoreCase(pkg.title, query)) return true;
    if (pkg.description) |description| {
        if (containsIgnoreCase(description, query)) return true;
    }
    if (pkg.keywords) |keywords| {
        for (keywords) |keyword| {
            if (containsIgnoreCase(keyword, query)) return true;
        }
    }
    if (pkg.categories) |categories| {
        for (categories) |category| {
            if (containsIgnoreCase(category, query)) return true;
        }
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn packageRefFromUrl(url: []const u8) !PackageRef {
    var parts = std.mem.tokenizeScalar(u8, url, '/');
    _ = parts.next();
    const packages_segment = parts.next() orelse return error.InvalidPackageUrl;
    const owner = parts.next() orelse return error.InvalidPackageUrl;
    const repo = parts.next() orelse return error.InvalidPackageUrl;
    if (!std.mem.eql(u8, packages_segment, "packages")) return error.InvalidPackageUrl;
    return .{ .owner = owner, .repo = repo };
}

fn cloneOrUpdateRepo(allocator: Allocator, repo_url: []const u8, repo_dir: []const u8) !void {
    if (dirExistsAbsolute(repo_dir)) {
        try runCommand(allocator, repo_dir, &.{ "git", "pull", "--ff-only" });
        return;
    }

    const parent = std.fs.path.dirname(repo_dir) orelse return error.InvalidPath;
    try ensureDirAbsolute(parent);
    try runCommand(allocator, null, &.{ "git", "clone", repo_url, repo_dir });
}

fn dirExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn detectRequiredZigVersion(allocator: Allocator, repo_dir: []const u8) ![]u8 {
    const zon_path = try std.fs.path.join(allocator, &.{ repo_dir, "build.zig.zon" });
    defer allocator.free(zon_path);

    const cwd = std.fs.cwd();
    const contents = cwd.readFileAlloc(allocator, zon_path, 512 * 1024) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, DEFAULT_ZIG_VERSION),
        else => return err,
    };
    defer allocator.free(contents);

    if (extractMinimumZigVersion(contents)) |version| {
        return allocator.dupe(u8, version);
    }

    return allocator.dupe(u8, DEFAULT_ZIG_VERSION);
}

fn extractMinimumZigVersion(contents: []const u8) ?[]const u8 {
    const key = "minimum_zig_version";
    const key_index = std.mem.indexOf(u8, contents, key) orelse return null;
    const tail = contents[key_index + key.len ..];
    const first_quote = std.mem.indexOfScalar(u8, tail, '"') orelse return null;
    const after_first = tail[first_quote + 1 ..];
    const second_quote = std.mem.indexOfScalar(u8, after_first, '"') orelse return null;
    return after_first[0..second_quote];
}

fn ensureZvmAvailable(allocator: Allocator) ![]u8 {
    if (findExecutableInPath(allocator, "zvm")) |path| return path else |_| {}

    const home = try getEnvOwned(allocator, "HOME");
    defer allocator.free(home);

    const candidate = try std.fs.path.join(allocator, &.{ home, ".zvm", "self", "zvm" });
    if (std.fs.accessAbsolute(candidate, .{})) |_| {
        return candidate;
    } else |_| {
        allocator.free(candidate);
    }

    std.log.err("zvm not found. install it first with curl -fsSL https://www.zvm.app/install.sh | bash", .{});
    return error.ZvmNotFound;
}

fn findExecutableInPath(allocator: Allocator, exe_name: []const u8) ![]u8 {
    const path_env = try getEnvOwned(allocator, "PATH");
    defer allocator.free(path_env);

    var iter = std.mem.tokenizeScalar(u8, path_env, std.fs.path.delimiter);
    while (iter.next()) |segment| {
        const candidate = try std.fs.path.join(allocator, &.{ segment, exe_name });
        if (std.fs.accessAbsolute(candidate, .{})) |_| {
            return candidate;
        } else |_| {
            allocator.free(candidate);
        }
    }
    return error.FileNotFound;
}

fn findBuiltBinary(allocator: Allocator, repo_dir: []const u8, package_name: []const u8) ![]u8 {
    const bin_dir_path = try std.fs.path.join(allocator, &.{ repo_dir, "zig-out", "bin" });
    defer allocator.free(bin_dir_path);

    const exact = try std.fs.path.join(allocator, &.{ bin_dir_path, package_name });
    if (std.fs.accessAbsolute(exact, .{})) |_| {
        return exact;
    } else |_| {
        allocator.free(exact);
    }

    var dir = try std.fs.openDirAbsolute(bin_dir_path, .{ .iterate = true });
    defer dir.close();

    var iterator = dir.iterate();
    var found: ?[]u8 = null;
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (found != null) return error.AmbiguousBuildOutput;
        found = try std.fs.path.join(allocator, &.{ bin_dir_path, entry.name });
    }

    return found orelse error.BinaryNotFound;
}

fn copyFileAbsolute(source_path: []const u8, destination_path: []const u8) !void {
    try std.fs.copyFileAbsolute(source_path, destination_path, .{});
    var destination = try std.fs.openFileAbsolute(destination_path, .{ .mode = .read_write });
    defer destination.close();
    try destination.chmod(0o755);
}

fn runCommand(allocator: Allocator, cwd: ?[]const u8, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.log.err("command failed with exit code {d}: {s}", .{ code, argv[0] });
                return error.CommandFailed;
            }
        },
        else => {
            std.log.err("command terminated unexpectedly: {s}", .{argv[0]});
            return error.CommandFailed;
        },
    }
}
