//! h9x's build (design/prototype.md, "One program, two binaries"):
//!
//!   zig build              h9x and h9x-runner, in zig-out/bin
//!   zig build test         the unit tests
//!   zig build run -- ARGS  h9x
//!   zig build design -- C  the design tool (design/README.md)
//!
//! Both programs are one module tree on h9's library, the `h9` package in
//! build.zig.zon. h9x embeds the host target's runner and the guest
//! scripts.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;
    const version = b.option([]const u8, "version", "Version h9x --version reports (default: build.zig.zon's)") orelse
        @import("build.zig.zon").version;

    // h9x builds no GUI, so h9 needs no window system's libraries.
    const h9 = b.dependency("h9", .{ .target = target, .optimize = optimize, .gfx = .none });
    const h9_mod = h9.module("h9");

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    // h9x-runner: h9, the pack reader, and the container lookup, through
    // the `h9x` module (src/root.zig), with none of the builder.
    const shared = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "h9", .module = h9_mod }},
    });
    const runner_mod = b.createModule(.{
        .root_source_file = b.path("src/runner/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "h9", .module = h9_mod },
            .{ .name = "h9x", .module = shared },
            // h9's CLI reads stdin for the console this way, cancellably.
            .{ .name = "h9_stdin", .module = b.createModule(.{
                .root_source_file = h9.path("src/stdin.zig"),
                .target = target,
                .optimize = optimize,
            }) },
        },
    });
    const runner = b.addExecutable(.{ .name = "h9x-runner", .root_module = runner_mod });
    macos(b, runner, os);
    // pack adds a load command for the __H9X segment, and one for the
    // signature if there's none, after the runner's own (src/exe/macho.zig).
    // Zig's linker leaves no room there unless asked.
    runner.headerpad_size = macho_headerpad;

    // h9x: the CLI, with the guest scripts and the host's runner embedded.
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "h9", .module = h9_mod }},
    });
    mod.addOptions("build_options", options);
    mod.addAnonymousImport("build_sh", .{ .root_source_file = b.path("guest/build.sh") });
    mod.addAnonymousImport("roots_sh", .{ .root_source_file = b.path("guest/roots.sh") });
    mod.addAnonymousImport("h9x_runner", .{ .root_source_file = runner.getEmittedBin() });
    const exe = b.addExecutable(.{ .name = "h9x", .root_module = mod });
    macos(b, exe, os);

    const install_exe = b.addInstallArtifact(exe, .{});
    const install_runner = b.addInstallArtifact(runner, .{});
    b.getInstallStep().dependOn(&install_exe.step);
    b.getInstallStep().dependOn(&install_runner.step);

    // HVF refuses hv_vm_create without the hypervisor entitlement, so the
    // installed programs are signed ad hoc on a Mac. The runner embedded in
    // h9x isn't: pack signs each executable it makes.
    var ready = &install_exe.step;
    if (os == .macos and b.graph.host.result.os.tag == .macos) {
        inline for (.{ .{ exe, &install_exe.step }, .{ runner, &install_runner.step } }, 0..) |pair, i| {
            const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--entitlements" });
            sign.addFileArg(b.path("h9x.entitlements"));
            sign.addFileArg(b.graph.path(.install_bin, pair[0].out_filename));
            sign.step.dependOn(pair[1]);
            b.getInstallStep().dependOn(&sign.step);
            if (i == 0) ready = &sign.step;
        }
    }

    const run_cmd = std.Build.Step.Run.create(b, "run h9x");
    run_cmd.addFileArg(b.graph.path(.install_bin, exe.out_filename));
    run_cmd.step.dependOn(ready);
    run_cmd.addPassthruArgs();
    b.step("run", "Run h9x").dependOn(&run_cmd.step);

    // The unit tests: every module's, through src/main.zig's test block,
    // and the runner's.
    const test_step = b.step("test", "Run the unit tests");
    for ([_]*std.Build.Module{ mod, runner_mod }) |m| {
        const t = b.addTest(.{ .root_module = m });
        macos(b, t, os);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // The executable containers on real runners (src/exe_test.zig): a
    // stand-in runner built for each container's OS, the Linux one for the
    // host's architecture so the test can run it.
    const exe_test_mod = b.createModule(.{
        .root_source_file = b.path("src/exe_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const host_arch = target.result.cpu.arch;
    const fixtures = [_]struct { []const u8, []const u8 }{
        .{ "fixture_elf", if (os == .linux and (host_arch == .x86_64 or host_arch == .aarch64)) b.fmt("{t}-linux-musl", .{host_arch}) else "x86_64-linux-musl" },
        .{ "fixture_macho", "aarch64-macos" },
        .{ "fixture_pe", "x86_64-windows-gnu" },
    };
    for (fixtures) |f| {
        const fixture = b.addExecutable(.{ .name = f[0], .root_module = b.createModule(.{
            .root_source_file = b.path("src/exe/testdata/runner.zig"),
            .target = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = f[1] }) catch unreachable),
            .optimize = .ReleaseSmall,
            .strip = true,
        }) });
        fixture.headerpad_size = macho_headerpad;
        exe_test_mod.addAnonymousImport(f[0], .{ .root_source_file = fixture.getEmittedBin() });
    }
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe_test_mod })).step);

    // The real runner joined with a pack and run (src/runner_test.zig).
    const runner_test_mod = b.createModule(.{
        .root_source_file = b.path("src/runner_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "h9", .module = h9_mod }},
    });
    runner_test_mod.addAnonymousImport("h9x_runner", .{ .root_source_file = runner.getEmittedBin() });
    const runner_test = b.addTest(.{ .root_module = runner_test_mod });
    macos(b, runner_test, os);
    // The runner is signed when it's joined, so the test runs it as is.
    test_step.dependOn(&b.addRunArtifact(runner_test).step);

    // The design tool (design/README.md, The tool), run from the
    // repository root: zig build design -- <command>.
    const design_tool = b.addExecutable(.{
        .name = "design",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/design.zig"),
            .target = b.graph.host,
        }),
    });
    const run_design = b.addRunArtifact(design_tool);
    run_design.setCwd(b.path("."));
    run_design.has_side_effects = true;
    run_design.stdio = .inherit;
    run_design.addPassthruArgs();
    b.step("design", "Run the design tool: zig build design -- <command> (help lists them)").dependOn(&run_design.step);
    // Its tests read tools/testdata from the repository root.
    const design_tests = b.addRunArtifact(b.addTest(.{ .root_module = design_tool.root_module }));
    design_tests.setCwd(b.path("."));
    test_step.dependOn(&design_tests.step);
}

/// Room after a Mach-O runner's load commands for the two pack adds.
const macho_headerpad = 0x400;

/// What a program on h9 needs on macOS: the Hypervisor framework, and the
/// SDK's paths when SDKROOT names one.
fn macos(b: *std.Build, c: *std.Build.Step.Compile, os: std.Target.Os.Tag) void {
    if (os != .macos) return;
    if (b.graph.environ_map.get("SDKROOT")) |sdk| {
        const m = c.root_module;
        m.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
        m.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
        m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
    }
    c.root_module.linkFramework("Hypervisor", .{});
}
