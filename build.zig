// SPDX-License-Identifier: EUPL-1.2
const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    // the std sources matching the compiler that builds us, used to resolve
    // `@import("std")`. falls back to `zig env` at runtime when unset
    options.addOption(?[]const u8, "zig_std_dir", b.option(
        []const u8,
        "zig-std-dir",
        "Default std source directory to resolve @import(\"std\") against",
    ));

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

    const run = b.addRunArtifact(exe);
    // `zig build run -- args`, which became a method in 0.17
    if (@hasDecl(std.Build.Step.Run, "addPassthruArgs")) {
        run.addPassthruArgs();
    } else if (b.args) |args| {
        run.addArgs(args);
    }
    b.step("run", "Run scip-zig").dependOn(&run.step);
}
