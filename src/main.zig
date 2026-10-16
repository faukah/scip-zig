// SPDX-License-Identifier: EUPL-1.2
//! scip-zig: a SCIP indexer for zig

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Analyzer = @import("Analyzer.zig");
const build_scan = @import("build_scan.zig");
const Emitter = @import("Emitter.zig");
const manifest = @import("manifest.zig");
const Encoder = @import("protobuf.zig").Encoder;
const scip = @import("scip.zig");

const usage =
    \\usage: scip-zig index [options]
    \\
    \\Index every .zig file below the project root into a SCIP index.
    \\This build parses zig {s} source.
    \\
    \\Dependencies in build.zig.zon are read from where `zig build` unpacks
    \\them, zig-pkg/ in the project root or $ZIG_LOCAL_PKG_DIR, so run
    \\`zig build --fetch` first.
    \\
    \\options:
    \\  --project-root <dir>     project to index (default: .)
    \\  --output <file>          where to write the index (default: index.scip)
    \\  --module <name>=<path>   resolve @import("name") to the root file at path,
    \\                           on top of the modules build.zig declares,
    \\                           may be repeated
    \\  --package-name <name>    package name in symbols (default: from build.zig.zon)
    \\  --package-version <ver>  package version in symbols (default: from build.zig.zon)
    \\  --zig-std-dir <dir>      std sources to resolve @import("std") against
    \\                           (default: the std installed with scip-zig,
    \\                           else `zig env`'s)
    \\  -h, --help               show this help
    \\  --version                show the version
    \\
;

const Options = struct {
    project_root: []const u8 = ".",
    output: []const u8 = "index.scip",
    modules: std.ArrayList([]const u8) = .empty,
    package_name: ?[]const u8 = null,
    package_version: ?[]const u8 = null,
    zig_std_dir: ?[]const u8 = null,
};

/// directories never indexed, besides hidden ones
const skipped_dirs = [_][]const u8{ "zig-out", "zig-pkg", "zig-cache" };

pub fn main(init: std.process.Init) !void {
    mainInner(init) catch |err| switch (err) {
        // already printed
        error.Reported => std.process.exit(1),
        else => |e| return e,
    };
}

fn mainInner(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var options: Options = .{};
    if (args.len < 2) return fail("{s}", .{try usageText(arena)});
    const command = args[1];
    if (eql(command, "-h") or eql(command, "--help")) {
        std.debug.print("{s}", .{try usageText(arena)});
        return;
    }
    if (eql(command, "--version")) {
        std.debug.print("scip-zig {s} (zig {s})\n", .{ build_options.version, builtin.zig_version_string });
        return;
    }
    if (!eql(command, "index")) return fail("unknown command '{s}'\n\n{s}", .{ command, try usageText(arena) });

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "-h") or eql(arg, "--help")) {
            std.debug.print("{s}", .{try usageText(arena)});
            return;
        }
        if (i + 1 >= args.len) return fail("unknown or incomplete option '{s}'", .{arg});
        const value = args[i + 1];
        i += 1;
        if (eql(arg, "--project-root")) {
            options.project_root = value;
        } else if (eql(arg, "--output")) {
            options.output = value;
        } else if (eql(arg, "--module")) {
            try options.modules.append(arena, value);
        } else if (eql(arg, "--package-name")) {
            options.package_name = value;
        } else if (eql(arg, "--package-version")) {
            options.package_version = value;
        } else if (eql(arg, "--zig-std-dir")) {
            options.zig_std_dir = value;
        } else {
            return fail("unknown option '{s}'", .{arg});
        }
    }

    const index = try run(arena, io, init.environ_map, options, args[1..]);
    var encoder: Encoder = .init(arena);
    try index.encode(&encoder);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = options.output, .data = encoder.buf.items });
}

fn run(arena: Allocator, io: Io, environ: *const std.process.Environ.Map, options: Options, arguments: []const []const u8) !scip.Index {
    const root = Io.Dir.cwd().realPathFileAlloc(io, options.project_root, arena) catch |err| {
        return fail("cannot open project root '{s}': {t}", .{ options.project_root, err });
    };

    var analyzer: Analyzer = .{ .arena = arena, .io = io };

    const project_manifest = manifest.read(arena, io, root);
    const project = try analyzer.addPackage(
        root,
        options.package_name orelse project_manifest.name orelse std.fs.path.basename(root),
        options.package_version orelse project_manifest.version orelse "",
    );

    if (options.zig_std_dir orelse installedStdDir(arena, io) orelse zigEnvStdDir(arena, io)) |std_dir| {
        const std_root = try Analyzer.normalize(arena, try absolute(arena, io, std_dir));
        const std_package = try analyzer.addPackage(std_root, "std", builtin.zig_version_string);
        try analyzer.addModule(null, "std", try std.fs.path.join(arena, &.{ std_root, "std.zig" }), std_package);
    } else {
        std.debug.print("warning: no zig std found, references into std stay unresolved\n", .{});
    }

    var packages: Packages = .{
        .analyzer = &analyzer,
        .arena = arena,
        .io = io,
        .pkg_dir = if (environ.get("ZIG_LOCAL_PKG_DIR")) |dir|
            try Analyzer.normalize(arena, try absolute(arena, io, dir))
        else
            try std.fs.path.join(arena, &.{ root, "zig-pkg" }),
    };
    try packages.roots.put(arena, root, project);
    try packages.addModules(project, root, project_manifest);
    // flags come last, so they override what build.zig declares
    for (options.modules.items) |spec| {
        const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return fail("--module expects <name>=<path>, got '{s}'", .{spec});
        const path = try Analyzer.normalize(arena, try absolute(arena, io, spec[eq + 1 ..]));
        try analyzer.addModule(project, spec[0..eq], path, try packages.fileModule(project, root, spec[0..eq], path));
    }

    const paths = try projectFiles(arena, io, root);
    var files: std.ArrayList(*Analyzer.File) = .empty;
    for (paths) |path| {
        // files of dependencies inside the project, like a path dependency in
        // a subdirectory, keep the dependency's symbols
        const file = analyzer.loadFile(path, analyzer.packageOf(path) orelse project) catch |err| {
            std.debug.print("warning: skipping {s}: {t}\n", .{ path, err });
            continue;
        };
        file.document = path[root.len + 1 ..];
        try files.append(arena, file);
    }

    var emitter: Emitter = .{ .analyzer = &analyzer, .arena = arena };
    var documents: std.ArrayList(scip.Document) = .empty;
    for (files.items) |file| try documents.append(arena, try emitter.document(file));

    return .{
        .metadata = .{
            .tool_info = .{
                .name = "scip-zig",
                .version = build_options.version,
                .arguments = arguments,
            },
            .project_root = try std.fmt.allocPrint(arena, "file://{s}", .{root}),
        },
        .documents = documents.items,
        .external_symbols = try emitter.externalSymbols(),
    };
}

/// the packages the project depends on, through build.zig.zon, and the
/// modules each of them declares in its build.zig
const Packages = struct {
    analyzer: *Analyzer,
    arena: Allocator,
    io: Io,
    /// where `zig build` unpacks fetched packages
    pkg_dir: []const u8,
    /// package by root directory
    roots: std.StringHashMapUnmanaged(u32) = .empty,
    /// modules a package exports with `b.addModule`, by package
    exports: std.AutoHashMapUnmanaged(u32, std.StringHashMapUnmanaged(Analyzer.Module)) = .empty,

    /// makes the modules `root`/build.zig declares importable from `package`
    fn addModules(p: *Packages, package: u32, root: []const u8, package_manifest: manifest.Manifest) !void {
        var exports: std.StringHashMapUnmanaged(Analyzer.Module) = .empty;
        for (try build_scan.modules(p.arena, p.io, root)) |module| {
            const resolved: Analyzer.Module = switch (module.source) {
                .file => |path| blk: {
                    const normalized = try Analyzer.normalize(p.arena, path);
                    break :blk .{ .root_file = normalized, .package = try p.fileModule(package, root, module.name, normalized) };
                },
                .dependency => |source| blk: {
                    const dep_package = try p.dependency(root, package_manifest, source.dependency) orelse continue;
                    const dependency_exports = p.exports.get(dep_package) orelse continue;
                    break :blk dependency_exports.get(source.module) orelse {
                        std.debug.print("warning: dependency '{s}' has no module '{s}'\n", .{ source.dependency, source.module });
                        continue;
                    };
                },
            };
            try p.analyzer.addModule(package, module.name, resolved.root_file, resolved.package);
            if (module.exported) try exports.put(p.arena, module.name, resolved);
        }
        try p.exports.put(p.arena, package, exports);
    }

    /// the package of a module with the root file `path`: its declaring
    /// package if inside of it, else one of its own
    fn fileModule(p: *Packages, package: u32, root: []const u8, name: []const u8, path: []const u8) !u32 {
        if (inside(root, path)) return package;
        return p.analyzer.addPackage(std.fs.path.dirname(path) orelse "/", name, "");
    }

    /// the package a dependency of `root` resolves to, loaded on first use
    /// recursive through `addModules`, so its error set is spelled out
    fn dependency(p: *Packages, root: []const u8, package_manifest: manifest.Manifest, name: []const u8) anyerror!?u32 {
        const dep = for (package_manifest.dependencies) |dep| {
            if (eql(dep.name, name)) break dep;
        } else {
            std.debug.print("warning: {s}/build.zig uses dependency '{s}' missing from its build.zig.zon\n", .{ root, name });
            return null;
        };
        const dir = try Analyzer.normalize(p.arena, switch (dep.location) {
            .path => |path| try std.fs.path.join(p.arena, &.{ root, path }),
            .hash => |hash| try std.fs.path.join(p.arena, &.{ p.pkg_dir, hash }),
        });
        if (p.roots.get(dir)) |package| return package;

        Io.Dir.cwd().access(p.io, dir, .{}) catch {
            std.debug.print("warning: dependency '{s}' not found at {s}, run `zig build --fetch`\n", .{ name, dir });
            return null;
        };
        const dep_manifest = manifest.read(p.arena, p.io, dir);
        const package = try p.analyzer.addPackage(dir, dep_manifest.name orelse name, dep_manifest.version orelse "");
        // before its modules, which may depend on it in a cycle
        try p.roots.put(p.arena, dir, package);
        try p.addModules(package, dir, dep_manifest);
        return package;
    }
};

fn inside(root: []const u8, path: []const u8) bool {
    return std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/';
}

/// absolute paths of all zig files below `root`, sorted
fn projectFiles(arena: Allocator, io: Io, root: []const u8) ![]const []const u8 {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walkSelectively(arena);
    defer walker.deinit();

    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (entry.basename[0] == '.') continue;
                for (skipped_dirs) |skipped| {
                    if (eql(entry.basename, skipped)) break;
                } else try walker.enter(io, entry);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                try paths.append(arena, try std.fs.path.join(arena, &.{ root, entry.path }));
            },
            else => {},
        }
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    return paths.items;
}

/// the std installed with scip-zig: `lib/zig/std` beside the `bin` it runs from
fn installedStdDir(arena: Allocator, io: Io) ?[]const u8 {
    const bin = std.process.executableDirPathAlloc(io, arena) catch return null;
    const dir = std.fs.path.join(arena, &.{ bin, "..", "lib", "zig", "std" }) catch return null;
    const root = std.fs.path.join(arena, &.{ dir, "std.zig" }) catch return null;
    Io.Dir.accessAbsolute(io, root, .{}) catch return null;
    return dir;
}

/// the `.std_dir` reported by `zig env`
fn zigEnvStdDir(arena: Allocator, io: Io) ?[]const u8 {
    const result = std.process.run(arena, io, .{ .argv = &.{ "zig", "env" } }) catch return null;
    const key = ".std_dir = \"";
    const start = (std.mem.indexOf(u8, result.stdout, key) orelse return null) + key.len;
    const end = std.mem.indexOfScalarPos(u8, result.stdout, start, '"') orelse return null;
    return result.stdout[start..end];
}

fn absolute(arena: Allocator, io: Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    const cwd = try std.process.currentPathAlloc(io, arena);
    return std.fs.path.join(arena, &.{ cwd, path });
}

fn usageText(arena: Allocator) ![]const u8 {
    return std.fmt.allocPrint(arena, usage, .{builtin.zig_version_string});
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn fail(comptime format: []const u8, args: anytype) error{Reported} {
    std.debug.print("error: " ++ format ++ "\n", args);
    return error.Reported;
}
