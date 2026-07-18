const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create modules — serialize first since core depends on it
    const serialize_mod = b.createModule(.{
        .root_source_file = b.path("src/serialize/serialize.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "serialize", .module = serialize_mod },
        },
    });

    const data_mod = b.createModule(.{
        .root_source_file = b.path("src/data/data.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
        },
    });

    const render_mod = b.createModule(.{
        .root_source_file = b.path("src/render/render.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "data", .module = data_mod },
        },
    });

    // Executable
    const exe = b.addExecutable(.{
        .name = "freeserf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "serialize", .module = serialize_mod },
                .{ .name = "render", .module = render_mod },
                .{ .name = "data", .module = data_mod },
            },
        }),
    });

    exe.root_module.link_libc = true;

    // Link system libraries for GLFW and OpenGL
    exe.root_module.linkSystemLibrary("glfw3", .{});
    if (target.result.os.tag == .macos) {
        exe.root_module.linkFramework("OpenGL", .{});
    } else {
        exe.root_module.linkSystemLibrary("GL", .{});
    }

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run Freeserf");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    // Test step for core module
    const core_tests = b.addTest(.{
        .root_module = core_mod,
    });
    const run_core_tests = b.addRunArtifact(core_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_core_tests.step);

    // Integration test: verify TPWM decompression + PAK parsing on real data
    const real_data_exe = b.addExecutable(.{
        .name = "test-real-data",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/test_real_data.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "data", .module = data_mod },
                .{ .name = "core", .module = core_mod },
                .{ .name = "serialize", .module = serialize_mod },
            },
        }),
    });
    real_data_exe.root_module.link_libc = true;

    const real_data_run = b.addRunArtifact(real_data_exe);
    const real_data_step = b.step("test-real-data", "Run integration test on real SPAE.PA file");
    real_data_step.dependOn(&real_data_run.step);

    // Sprite scanner
    const scan_exe = b.addExecutable(.{
        .name = "scan-sprites",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/scan_sprites.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "data", .module = data_mod },
                .{ .name = "core", .module = core_mod },
                .{ .name = "serialize", .module = serialize_mod },
            },
        }),
    });
    scan_exe.root_module.link_libc = true;
    const scan_run = b.addRunArtifact(scan_exe);
    const scan_step = b.step("scan-sprites", "Scan SPAE.PA sprite dimensions");
    scan_step.dependOn(&scan_run.step);

    // Check sprite IDs against C++ freeserf map_building_sprite
    const check_ids_exe = b.addExecutable(.{
        .name = "check-ids",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_mapobject.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "data", .module = data_mod },
                .{ .name = "core", .module = core_mod },
                .{ .name = "serialize", .module = serialize_mod },
            },
        }),
    });
    check_ids_exe.root_module.link_libc = true;
    const check_ids_run = b.addRunArtifact(check_ids_exe);
    const check_ids_step = b.step("check-ids", "Check building sprite IDs against C++ freeserf");
    check_ids_step.dependOn(&check_ids_run.step);

    // Check terrain alpha
    const check_alpha_exe = b.addExecutable(.{
        .name = "check-alpha",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_terrain_alpha.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "data", .module = data_mod },
                .{ .name = "core", .module = core_mod },
                .{ .name = "serialize", .module = serialize_mod },
            },
        }),
    });
    check_alpha_exe.root_module.link_libc = true;
    const check_alpha_run = b.addRunArtifact(check_alpha_exe);
    const check_alpha_step = b.step("check-alpha", "Check terrain sprite alpha/transparency");
    check_alpha_step.dependOn(&check_alpha_run.step);
}
