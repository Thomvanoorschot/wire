const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const xev_dep = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });

    const wire = b.addModule("wire", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
    });

    wire.addImport("xev", xev_dep.module("xev"));
}
