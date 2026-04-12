const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Fetch dependency modules
    const zchomd_dep = b.dependency("zchomd", .{ .target = target, .optimize = optimize });
    const zchomptic_dep = b.dependency("zchomptic", .{ .target = target, .optimize = optimize });
    const zcholor_dep = b.dependency("zcholor", .{ .target = target, .optimize = optimize });

    const zchomd_mod = zchomd_dep.module("zchomd");
    const zchomptic_mod = zchomptic_dep.module("zchomptic");
    const zcholor_mod = zcholor_dep.module("zcholor");

    // Library module (exposed to consumers)
    const mod = b.addModule("ziglow", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Executable
    const exe = b.addExecutable(.{
        .name = "ziglow",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ziglow", .module = mod },
                .{ .name = "zchomd", .module = zchomd_mod },
                .{ .name = "zchomptic", .module = zchomptic_mod },
                .{ .name = "zcholor", .module = zcholor_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run ziglow");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
