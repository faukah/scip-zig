// SPDX-License-Identifier: EUPL-1.2
const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const exe = b.addExecutable(.{
        .name = "scip-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    b.installArtifact(exe);
    // the std sources of the compiler that builds us, to resolve `@import("std")` against:
    // `lib/zig/std` beside `bin`, where scip-zig looks first, as zig finds its own lib
    b.installDirectory(.{
        .source_dir = zigStd(b),
        .install_dir = .lib,
        .install_subdir = "zig/std",
    });

    const run = b.addRunArtifact(exe);
    // `zig build run -- args`
    run.addPassthruArgs();
    b.step("run", "Run scip-zig").dependOn(&run.step);
}

/// `std` in the building compiler's lib directory
fn zigStd(_: *std.Build) std.Build.LazyPath {
    return .{ .relative = .{ .base = .zig_lib, .sub_path = "std" } };
}
