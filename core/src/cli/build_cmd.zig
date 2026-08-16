const std = @import("std");
const api = @import("../api.zig");
const fs = @import("fs.zig");
const MAX_FILE_SIZE = @import("config.zig").MAX_FILE_SIZE;
const VM = @import("../vm/vm.zig").VM;
const chunk = @import("../vm/chunk.zig");
const Compiler = @import("../compiler/compiler.zig").Compiler;
const registry = @import("../stdlib/registry.zig");
const stl = @import("../exporters/3d/stl.zig");

pub fn execute(init: std.process.Init, allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) !void {
    const file_path = args_iter.next() orelse {
        std.debug.print("Error: Missing input file path.\n\nUsage: kupcad build <file.kup> [-o <output.stl>] [--format stl]\n", .{});
        return;
    };

    var output_path: ?[]const u8 = null;
    var format: []const u8 = "stl";

    // Parse CLI flags
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output_path = args_iter.next();
        } else if (std.mem.eql(u8, arg, "--format")) {
            format = args_iter.next() orelse "stl";
        }
    }

    // Read the script
    const source = fs.readFileLimit(init.io, allocator, file_path, MAX_FILE_SIZE) catch |err| {
        std.debug.print("Error reading file '{s}': {}\n", .{ file_path, err });
        return;
    };
    defer allocator.free(source);

    // Parse the AST
    var doc = api.Document.parse(allocator, source) catch |err| {
        std.debug.print("Error parsing file '{s}': {}\n", .{ file_path, err });
        return;
    };
    defer doc.deinit();

    if (doc.diagnostics.len > 0) {
        std.debug.print("Syntax errors found in '{s}':\n", .{file_path});
        for (doc.diagnostics) |diag| {
            std.debug.print("- {s}\n", .{diag.message});
        }
        return;
    }

    // Set up the execution environment
    var vm = try VM.init(allocator, init.io);
    defer vm.deinit();
    vm.line_index = &doc.line_index;

    try registry.registerStandardLibrary(&vm);

    var main_chunk = chunk.Chunk.init();
    defer main_chunk.free(allocator);

    var compiler = Compiler.init(allocator, &doc.tree, doc.symbols, doc.tokens.starts, &main_chunk, &vm);
    compiler.compile(doc.tree.root) catch |err| {
        std.debug.print("Compilation failed: {}\n", .{err});
        return;
    };

    // Execute!
    std.debug.print("Executing '{s}'...\n", .{file_path});
    const result = vm.interpret(&main_chunk);

    if (result != .ok) {
        std.debug.print("Script execution halted with status: {}\n", .{result});
        return;
    }

    // Implicitly export the final geometry left on the stack
    if (vm.stack_top > 0) {
        const top_val = vm.stack[vm.stack_top - 1];

        if (top_val.isGeometry()) {
            // Determine default output path if none was provided
            var default_out_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const final_out_path = if (output_path) |p| p else blk: {
                const ext_idx = std.mem.lastIndexOf(u8, file_path, ".") orelse file_path.len;
                const base_name = file_path[0..ext_idx];
                break :blk try std.fmt.bufPrint(&default_out_buffer, "{s}.{s}", .{ base_name, format });
            };

            std.debug.print("Materializing Geometry...\n", .{});
            const handle = try vm.ensureConcrete(top_val);

            if (std.mem.eql(u8, format, "stl")) {
                try stl.writeStl(&vm, handle, final_out_path);
                std.debug.print("Successfully exported to {s}\n", .{final_out_path});
            } else {
                std.debug.print("Error: Unsupported export format '{s}'\n", .{format});
            }
        } else {
            std.debug.print("Script executed successfully. (Final value was not a Geometry, skipping implicit export)\n", .{});
        }
    }
}
