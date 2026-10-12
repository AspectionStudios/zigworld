const std = @import("std");
const population = @import("population_padded.zig");
const economy = @import("economy.zig");
const resources = @import("resources.zig");
const pollution = @import("pollution.zig");
const agriculture = @import("agriculture.zig");
const finance = @import("finance.zig");
const agents = @import("agents.zig");

const Demographics = population.Demographics;
const EconomyEngine = economy.EconomyEngine;
const ResourceEngine = resources.ResourceEngine;
const PollutionEngine = pollution.PollutionEngine;
const AgricultureEngine = agriculture.AgricultureEngine;
const FinanceEngine = finance.FinanceEngine;

pub const SimResult = struct {
    final_pop: f64,
    final_temp: f64,
    final_ic: f64,
};

// Wrap 103-year simulation loop into a pure function
pub fn runSimulation(prng: *std.rand.Random) SimResult {
    const calib = @import("calibration.zig").calib;
    
    // Generate Hardware-Aligned Curves
    const econ_curves = economy.generateDefaultCurves();
    const rsc_curves = resources.generateDefaultCurves();
    const pol_curves = pollution.generateDefaultCurves();
    const agr_curves = agriculture.generateDefaultCurves();
    const fin_curves = finance.generateDefaultCurves();
    _ = rsc_curves;

    var dem = Demographics.init();
    var econ = EconomyEngine{
        .state = .{
            .industrial_capital = calib.industrial_capital,
            .service_capital = calib.service_capital,
        },
    };
    var rsc = ResourceEngine.init();
    var pol = PollutionEngine.init();
    var agr = AgricultureEngine.init();
    var fin = FinanceEngine.init();
    
    // Initialize agents
    var agent_sys = agents.AgentSystem.init();
    
    // Monte Carlo: slightly perturb initial agent vulnerabilities by +/- 10%
    // This creates a lasting impact throughout the simulation.
    for (0..agents.NUM_HOUSEHOLDS) |i| {
        const perturb = 0.9 + 0.2 * prng.float(f32);
        agent_sys.vulnerability[i] *= perturb;
    }

    var atmospheric_carbon_gtc: f64 = calib.atmospheric_carbon_gtc;
    var temperature_anomaly: f64 = calib.temperature_anomaly;

    dem.loadInitialData(calib.init_m, calib.init_f);

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.05;

    const base_mort_m = [_]f64{0.01} ** 104;
    const base_mort_f = [_]f64{0.01} ** 104;

    const initial_econ = econ.step(&dem.state.males, &dem.state.females, &econ_curves);
    var last_rsc_out = rsc.step(dem.state.total_pop, initial_econ.industrial_output / dem.state.total_pop, 1.0);
    var last_pol_out = pol.step(dem.state.total_pop, last_rsc_out.pcrum, 5.0, 0.9e9, 1.0);
    var last_agr_out = agr.step(dem.state.total_pop, initial_econ.industrial_output, 3500.0, last_pol_out.ppolx, 1.6e12, 1.0);
    var last_fin_out = fin.step();

    for (0..103) |_| {
        last_fin_out = fin.step();
        const u_mult = last_fin_out.unemployment_multiplier;

        const total_pop = dem.state.total_pop;
        var total_labor: f64 = 0.0;
        var total_food_demand: f64 = 0.0;
        var total_energy: f64 = 0.0;

        for (0..104) |age| {
            const cohort_pop = dem.state.males[age] + dem.state.females[age];
            const vul = fin_curves.unemployment_vulnerability[age];
            const loss = (1.0 - u_mult) * vul;
            const eff_labor_mult = @max(0.0, 1.0 - loss);
            
            total_labor += cohort_pop * (econ_curves.labor_participation[age] * eff_labor_mult);
            total_food_demand += cohort_pop * agr_curves.food_demand_profile[age];
            total_energy += cohort_pop * econ_curves.energy_demand_profile[age];
        }

        const base_e_per_capita = total_energy / @max(1.0, total_pop);
        const agent_results = agent_sys.step(u_mult, base_e_per_capita, temperature_anomaly);

        const pop_scaling = total_pop / @as(f64, @floatFromInt(agents.NUM_HOUSEHOLDS));
        total_energy = agent_results.total_energy * pop_scaling;

        const total_savings_trillions = (agent_results.total_savings * pop_scaling) / 1_000_000_000_000.0;
        econ.state.industrial_capital += total_savings_trillions * 0.10;

        const fossil_fraction: f64 = 0.8;
        const fossil_twh = total_energy * fossil_fraction;
        
        const emissions = fossil_twh * 0.0001;
        atmospheric_carbon_gtc += emissions;
        
        temperature_anomaly = 3.0 * @log2(@max(1.0, atmospheric_carbon_gtc / 800.0));
        const damage_fraction = 1.0 - (1.0 / (1.0 + 0.00227 * temperature_anomaly * temperature_anomaly));
        
        econ.state.industrial_capital *= (1.0 - damage_fraction);
        agr.state.land_fertility *= (1.0 - damage_fraction * 0.1);

        const effective_ic = econ.state.industrial_capital * (1.0 - rsc.state.fcaor);
        const industrial_output = (@max(0.0, effective_ic) * 0.13184) * (total_labor / 1_000_000_000.0);
        const iopc = industrial_output / @max(1.0, total_pop);

        last_rsc_out = rsc.step(total_pop, iopc, 1.0);
        last_agr_out = agr.step(total_pop, industrial_output, iopc, pol.state.ppolx, total_food_demand, 1.0);
        last_pol_out = pol.step(total_pop, last_rsc_out.pcrum, last_agr_out.aiph, last_agr_out.arable_land, 1.0);

        const food_mort = AgricultureEngine.calculateMortalityMultiplier(last_agr_out.food_ratio, &agr_curves.starvation_vulnerability);
        const poll_mort = PollutionEngine.calculateMortalityMultiplier(last_pol_out.ppolx, &pol_curves.vulnerability_profile);

        var eff_mort_m: [104]f64 = undefined;
        var eff_mort_f: [104]f64 = undefined;

        for (0..104) |age| {
            const combined_mult = food_mort[age] * poll_mort[age];
            eff_mort_m[age] = @min(1.0, @max(0.0, base_mort_m[age] * combined_mult));
            eff_mort_f[age] = @min(1.0, @max(0.0, base_mort_f[age] * combined_mult));
        }

        dem.step(asfr, eff_mort_m, eff_mort_f);
    }
    
    // Prevent DCE
    std.mem.doNotOptimizeAway(&dem.state);
    
    return SimResult{
        .final_pop = dem.state.total_pop,
        .final_temp = temperature_anomaly,
        .final_ic = econ.state.industrial_capital,
    };
}

fn worker(runs: usize, seed: u64, result_pop: *f64, result_temp: *f64, result_ic: *f64) void {
    var prng_engine = std.rand.DefaultPrng.init(seed);
    var random = prng_engine.random();
    
    var sum_pop: f64 = 0.0;
    var sum_temp: f64 = 0.0;
    var sum_ic: f64 = 0.0;

    for (0..runs) |_| {
        const res = runSimulation(&random);
        sum_pop += res.final_pop;
        sum_temp += res.final_temp;
        sum_ic += res.final_ic;
    }
    result_pop.* = sum_pop;
    result_temp.* = sum_temp;
    result_ic.* = sum_ic;
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    
    const cpu_count = try std.Thread.getCpuCount();
    try stdout.print("=== Massive Monte Carlo ===\n", .{});
    try stdout.print("Detected CPU cores: {d}\n", .{cpu_count});
    
    const total_runs: usize = 100_000;
    const runs_per_thread = total_runs / cpu_count;
    const remaining_runs = total_runs % cpu_count;
    
    try stdout.print("Starting {d} runs across {d} threads...\n", .{total_runs, cpu_count});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    
    var threads = try allocator.alloc(std.Thread, cpu_count);
    defer allocator.free(threads);
    
    var pop_results = try allocator.alloc(f64, cpu_count);
    defer allocator.free(pop_results);
    var temp_results = try allocator.alloc(f64, cpu_count);
    defer allocator.free(temp_results);
    var ic_results = try allocator.alloc(f64, cpu_count);
    defer allocator.free(ic_results);
    
    var timer = try std.time.Timer.start();
    
    var seed_prng = std.rand.DefaultPrng.init(@as(u64, @intCast(std.time.timestamp())));
    
    for (0..cpu_count) |i| {
        const runs = if (i == cpu_count - 1) runs_per_thread + remaining_runs else runs_per_thread;
        threads[i] = try std.Thread.spawn(.{}, worker, .{runs, seed_prng.random().int(u64), &pop_results[i], &temp_results[i], &ic_results[i]});
    }
    
    var total_pop: f64 = 0.0;
    var total_temp: f64 = 0.0;
    var total_ic: f64 = 0.0;

    for (0..cpu_count) |i| {
        threads[i].join();
        total_pop += pop_results[i];
        total_temp += temp_results[i];
        total_ic += ic_results[i];
    }
    
    const elapsed_ns = timer.read();
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const avg_pop = total_pop / @as(f64, @floatFromInt(total_runs));
    const avg_temp = total_temp / @as(f64, @floatFromInt(total_runs));
    const avg_ic = total_ic / @as(f64, @floatFromInt(total_runs));
    
    try stdout.print("\n=== Results ===\n", .{});
    try stdout.print("Total execution time: {d:.2} s\n", .{elapsed_s});
    try stdout.print("Average time per simulation: {d:.2} us\n", .{(elapsed_s * 1_000_000.0) / @as(f64, @floatFromInt(total_runs))});
    try stdout.print("Average Final Population: {d:.2} million\n", .{avg_pop / 1_000_000.0});
    try stdout.print("Average Final Temperature Anomaly: +{d:.2} C\n", .{avg_temp});
    try stdout.print("Average Final Industrial Capital: ${d:.2} Trillion\n", .{avg_ic});
}
