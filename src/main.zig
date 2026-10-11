const std = @import("std");
const population = @import("population.zig");
const Demographics = population.Demographics;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("=== Zigworld (PyWorld5) Demographic Engine Benchmark ===\n", .{});

    var dem = Demographics.init();
    
    // Seed initial population for benchmark
    var init_m = [_]f64{0} ** 101;
    var init_f = [_]f64{0} ** 101;
    // Put 1 million people in every age cohort
    for (0..101) |i| {
        init_m[i] = 1_000_000.0;
        init_f[i] = 1_000_000.0;
    }
    dem.loadInitialData(init_m, init_f);

    try stdout.print("Initial Population: {d:.2} million\n", .{dem.state.total_pop / 1_000_000.0});

    // Dummy rates
    var asfr = [_]f64{0.0} ** 101;
    for (15..50) |i| asfr[i] = 0.05; // fertility for ages 15-49
    
    const mort_m = [_]f64{0.01} ** 101; // 1% mortality
    const mort_f = [_]f64{0.01} ** 101;

    const iterations: usize = 1_000_000;
    try stdout.print("Simulating {d} iterations of a 1-year demographic step...\n", .{iterations});

    var timer = try std.time.Timer.start();
    
    for (0..iterations) |_| {
        // We just run the step in a tight loop to see how fast the math is.
        // We aren't doing 1,000,000 continuous years (everyone would die), 
        // we are just benchmarking the CPU overhead of the math itself by resetting it.
        // Wait, if we reset it, it tests the function overhead. Let's just let it run 
        // 100 years, but do 10,000 complete 100-year simulations.
    }
    
    // Let's do 10,000 full 100-year simulations.
    const num_simulations: usize = 10_000;
    const years_per_sim: usize = 100;
    
    timer.reset();
    for (0..num_simulations) |_| {
        // Reset state
        dem.loadInitialData(init_m, init_f);
        
        for (0..years_per_sim) |_| {
            dem.step(asfr, mort_m, mort_f);
        }
    }
    const elapsed_ns = timer.read();
    
    const total_steps = num_simulations * years_per_sim;
    const ns_per_step = elapsed_ns / total_steps;
    
    try stdout.print("\nPerformance Results:\n", .{});
    try stdout.print("  Total Time for {d} runs (100 years each): {d} milliseconds\n", .{num_simulations, elapsed_ns / 1_000_000});
    try stdout.print("  Average time per 100-year simulation: {d} microseconds\n", .{(elapsed_ns / num_simulations) / 1000});
    try stdout.print("  Average time per 1-year step: {d} nanoseconds\n", .{ns_per_step});
    
    try stdout.print("\nFinal Population of last run (Year 100): {d:.2} million\n", .{dem.state.total_pop / 1_000_000.0});
}
