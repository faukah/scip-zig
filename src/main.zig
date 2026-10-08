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
const Encoder = @import("protobuf.zig").Encoder;
const scip = @import("scip.zig");

const usage =
    \\usage: scip-zig index [options]
    \\
    \\Index every .zig file below the project root into a SCIP index.
    \\This build parses zig {s} source.
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
    \\                           (default: {s})
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
    zig_std_dir: ?[]const u8 = build_options.zig_std_dir,
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

    const index = try run(arena, io, options, args[1..]);
    var encoder: Encoder = .init(arena);
    try index.encode(&encoder);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = options.output, .data = encoder.buf.items });
}

fn run(arena: Allocator, io: Io, options: Options, arguments: []const []const u8) !scip.Index {
    const root = Io.Dir.cwd().realPathFileAlloc(io, options.project_root, arena) catch |err| {
        return fail("cannot open project root '{s}': {t}", .{ options.project_root, err });
    };

    var analyzer: Analyzer = .{ .arena = arena, .io = io };

    const manifest = readManifest(arena, io, root);
    const project = try analyzer.addPackage(
        root,
        options.package_name orelse manifest.name orelse std.fs.path.basename(root),
        options.package_version orelse manifest.version orelse "",
    );

    if (options.zig_std_dir orelse zigEnvStdDir(arena, io)) |std_dir| {
        const std_root = try Analyzer.normalize(arena, try absolute(arena, io, std_dir));
        const std_package = try analyzer.addPackage(std_root, "std", builtin.zig_version_string);
        try analyzer.addModule("std", try std.fs.path.join(arena, &.{ std_root, "std.zig" }), std_package);
    } else {
        std.debug.print("warning: no zig std found, references into std stay unresolved\n", .{});
    }

    // flags come last, so they override what build.zig declares
    for (try build_scan.modules(arena, io, root)) |module| {
        try addModule(&analyzer, project, root, module.name, try Analyzer.normalize(arena, module.root_file));
    }
    for (options.modules.items) |spec| {
        const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return fail("--module expects <name>=<path>, got '{s}'", .{spec});
        const path = try Analyzer.normalize(arena, try absolute(arena, io, spec[eq + 1 ..]));
        try addModule(&analyzer, project, root, spec[0..eq], path);
    }

    const paths = try projectFiles(arena, io, root);
    var files: std.ArrayList(*Analyzer.File) = .empty;
    for (paths) |path| {
        const file = analyzer.loadFile(path, project) catch |err| {
            std.debug.print("warning: skipping {s}: {t}\n", .{ path, err });
            continue;
        };
        file.document = true;
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
        .external_symbols = emitter.externals.values(),
    };
}

/// modules inside the project belong to its package, others get their own
fn addModule(analyzer: *Analyzer, project: u32, root: []const u8, name: []const u8, path: []const u8) !void {
    const inside = std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/';
    const package = if (inside) project else try analyzer.addPackage(std.fs.path.dirname(path) orelse "/", name, "");
    try analyzer.addModule(name, path, package);
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

const Manifest = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
};

/// top-level `.name` and `.version` of build.zig.zon, if there is one
fn readManifest(arena: Allocator, io: Io, root: []const u8) Manifest {
    const path = std.fs.path.join(arena, &.{ root, "build.zig.zon" }) catch return .{};
    const source = Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(1 << 20), .of(u8), 0) catch return .{};

    var manifest: Manifest = .{};
    var tokenizer: std.zig.Tokenizer = .init(source);
    var depth: usize = 0;
    var previous: [3]std.zig.Token = undefined;
    var seen: usize = 0;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => break,
            .l_brace => depth += 1,
            .r_brace => depth -|= 1,
            else => {},
        }
        // `.field = value` at the top level
        if (depth == 1 and seen >= 3 and previous[0].tag == .period and previous[1].tag == .identifier and previous[2].tag == .equal) {
            const field = source[previous[1].loc.start..previous[1].loc.end];
            const value = source[token.loc.start..token.loc.end];
            if (eql(field, "name")) {
                if (token.tag == .period) {
                    const name = tokenizer.next();
                    manifest.name = source[name.loc.start..name.loc.end];
                } else if (token.tag == .string_literal) {
                    manifest.name = value[1 .. value.len - 1];
                }
            } else if (eql(field, "version") and token.tag == .string_literal) {
                manifest.version = value[1 .. value.len - 1];
            }
        }
        previous[0] = previous[1];
        previous[1] = previous[2];
        previous[2] = token;
        seen += 1;
    }
    return manifest;
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
    return std.fmt.allocPrint(arena, usage, .{ builtin.zig_version_string, build_options.zig_std_dir orelse "`zig env`" });
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn fail(comptime format: []const u8, args: anytype) error{Reported} {
    std.debug.print("error: " ++ format ++ "\n", args);
    return error.Reported;
}
