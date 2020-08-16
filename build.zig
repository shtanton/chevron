const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("chevron", "src/main.zig");
    exe.setBuildMode(mode);

    exe.install();
}
