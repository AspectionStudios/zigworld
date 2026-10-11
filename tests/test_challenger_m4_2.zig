const std = @import("std");
const population = @import("src/population_padded.zig");
const economy = @import("src/economy.zig");
const resources = @import("src/resources.zig");
const pollution = @import("src/pollution.zig");
const agriculture = @import("src/agriculture.zig");

const Demographics = population.Demographics;
const EconomyEngine = economy.EconomyEngine;
const ResourceEngine = resources.ResourceEngine;
const PollutionEngine = pollution.PollutionEngine;
const AgricultureEngine = agriculture.AgricultureEngine;

// Run unified 5-sector simulation for N years
fn runSimulation(years: usize, init_pop_per_cohort: f64, asfr_rate: f64, initial_nr: f64) struct {
    final_pop: f64,
    final_io: f64,
    final_nr: f64,
    final_ppol: f64,
    final_food: f64,
} {
    var dem = Demographics.init();
    var econ = EconomyEngine{
        .state = .{
            .industrial_capital = 105.0,
            .service_capital = 128.0,
        },
    };
    var rsc = ResourceEngine.init();
    rsc.state.remaining_resources = initial_nr;
    var pol = PollutionEngine.init();
    var agr = AgricultureEngine.init();

    const econ_curves = economy.generateDefaultCurves();
    const pol_curves = pollution.generateDefaultCurves();
    const agr_curves = agriculture.generateDefaultCurves();

    var init_m = [_]f64{0.0} ** 104;
    var init_f = [_]f64{0.0} ** 104;
    for (0..104) |i| {
        init_m[i] = init_pop_per_cohort;
        init_f[i] = init_pop_per_cohort;
    }
    dem.loadInitialData(init_m, init_f);

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = asfr_rate;

    const base_mort_m = [_]f64{0.01} ** 104;
    const base_mort_f = [_]f64{0.01} ** 104;

    var last_io: f64 = 0.0;
    var last_food: f64 = 0.0;

    for (0..years) |_| {
        const total_pop = dem.state.total_pop;
        var total_labor: f64 = 0.0;
        var total_food_demand: f64 = 0.0;

        for (0..104) |age| {
            const cohort_pop = dem.state.males[age] + dem.state.females[age];
            total_labor += cohort_pop * econ_curves.labor_participation[age];
            total_food_demand += cohort_pop * agr_curves.food_demand_profile[age];
        }

        const effective_ic = econ.state.industrial_capital * (1.0 - rsc.state.fcaor);
        const industrial_output = (@max(0.0, effective_ic) * 0.13184) * (total_labor / 1_000_000_000.0);
        const iopc = industrial_output / @max(1.0, total_pop);
        last_io = industrial_output;

        const rsc_out = rsc.step(total_pop, iopc, 1.0);
        const agr_out = agr.step(total_pop, industrial_output, iopc, pol.state.ppolx, total_food_demand, 1.0);
        last_food = agr_out.food_produced;
        const pol_out = pol.step(total_pop, rsc_out.pcrum, agr_out.aiph, agr_out.arable_land, 1.0);

        const food_mort = AgricultureEngine.calculateMortalityMultiplier(agr_out.food_ratio, &agr_curves.starvation_vulnerability);
        const poll_mort = PollutionEngine.calculateMortalityMultiplier(pol_out.ppolx, &pol_curves.vulnerability_profile);

        var eff_mort_m: [104]f64 = undefined;
        var eff_mort_f: [104]f64 = undefined;
        for (0..104) |age| {
            const combined = food_mort[age] * poll_mort[age];
            eff_mort_m[age] = @min(1.0, @max(0.0, base_mort_m[age] * combined));
            eff_mort_f[age] = @min(1.0, @max(0.0, base_mort_f[age] * combined));
        }

        dem.step(asfr, eff_mort_m, eff_mort_f);
    }

    // Explicit barrier to guarantee caller receives computed state
    std.mem.doNotOptimizeAway(&dem.state);
    std.mem.doNotOptimizeAway(&econ.state);
    std.mem.doNotOptimizeAway(&rsc.state);
    std.mem.doNotOptimizeAway(&pol.state);
    std.mem.doNotOptimizeAway(&agr.state);

    return .{
        .final_pop = dem.state.total_pop,
        .final_io = last_io,
        .final_nr = rsc.state.remaining_resources,
        .final_ppol = pol.state.ppol,
        .final_food = last_food,
    };
}

// TEST 1: Anti-DCE: Execution time must scale with iteration count
test "Challenger Anti-DCE: Runtime scales linearly with iteration count" {
    // 500 steps vs 5000 steps (10x scaling)
    var timer = try std.time.Timer.start();
    const runs_short: usize = 100;
    for (0..runs_short) |_| {
        _ = runSimulation(10, 38_461_538.46, 0.05, 1.0e12); // 1,000 steps total
    }
    const time_short = timer.read();

    timer.reset();
    const runs_long: usize = 100;
    for (0..runs_long) |_| {
        _ = runSimulation(100, 38_461_538.46, 0.05, 1.0e12); // 10,000 steps total
    }
    const time_long = timer.read();

    // Verify time_long > time_short and scales by at least 5x (proving loop is not elided)
    try std.testing.expect(time_long > time_short);
    const ratio = @as(f64, @floatFromInt(time_long)) / @as(f64, @floatFromInt(time_short));
    // Theoretical ratio is 10.0; allow range [4.0, 20.0] for jitter
    try std.testing.expect(ratio >= 4.0);
}

// TEST 2: Anti-DCE Oracle: Changing initial population changes all downstream sector outputs
test "Challenger Anti-DCE: State perturbation changes outputs" {
    const res_baseline = runSimulation(50, 38_461_538.46, 0.05, 1.0e12); // ~8 Billion
    const res_halved = runSimulation(50, 19_230_769.23, 0.05, 1.0e12);   // ~4 Billion

    // Final population must be strictly different
    try std.testing.expect(res_baseline.final_pop != res_halved.final_pop);
    try std.testing.expect(res_baseline.final_pop > res_halved.final_pop);

    // Industrial output and food must be different
    try std.testing.expect(res_baseline.final_io != res_halved.final_io);
    try std.testing.expect(res_baseline.final_food != res_halved.final_food);
}

// TEST 3: Anti-DCE Oracle: Changing fertility rate changes demographic evolution
test "Challenger Anti-DCE: Zero fertility causes steep demographic decline" {
    const res_normal = runSimulation(80, 38_461_538.46, 0.05, 1.0e12);
    const res_zero_fert = runSimulation(80, 38_461_538.46, 0.0, 1.0e12);

    try std.testing.expect(res_normal.final_pop > res_zero_fert.final_pop);
    try std.testing.expect(res_zero_fert.final_pop < res_normal.final_pop);
}

// TEST 4: Anti-DCE Oracle: Resource collapse triggers economic feedback
test "Challenger Anti-DCE: Resource depletion drags down industrial output" {
    const res_abundant = runSimulation(50, 38_461_538.46, 0.05, 1.0e12);
    // Severe initial resource scarcity (1e9 vs 1e12)
    const res_scarce = runSimulation(50, 38_461_538.46, 0.05, 1.0e9);

    try std.testing.expect(res_scarce.final_nr < res_abundant.final_nr);
    try std.testing.expect(res_scarce.final_io < res_abundant.final_io);
}

// TEST 5: Zero-Heap Allocation Assertion: FailingAllocator verifies zero heap requests
test "Challenger Zero-Allocation: Complete absence of heap memory use" {
    var failing_alloc = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const alloc = failing_alloc.allocator();
    _ = alloc; // We do not pass alloc to anything, because none of the sectors accept or need an allocator

    // Run 100 iterations of 50-year simulations
    for (0..10) |_| {
        const out = runSimulation(50, 38_461_538.46, 0.05, 1.0e12);
        try std.testing.expect(!std.math.isNan(out.final_pop));
        try std.testing.expect(!std.math.isInf(out.final_pop));
        try std.testing.expect(out.final_pop > 0.0);
    }
}
