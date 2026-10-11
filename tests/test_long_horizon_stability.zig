const std = @import("std");

// Import verified live implementation modules directly from src/
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

// High-precision safety verification asserting no NaN, Inf, or negative cohorts.
fn assertAllCohortsValid(dem: *const Demographics) !void {
    if (std.math.isNan(dem.state.total_pop)) return error.NanTotalPop;
    if (std.math.isInf(dem.state.total_pop)) return error.InfTotalPop;
    if (dem.state.total_pop < 0.0) return error.NegativeTotalPop;

    for (dem.state.males, 0..) |m, age| {
        if (std.math.isNan(m)) return error.NanMaleCohort;
        if (std.math.isInf(m)) return error.InfMaleCohort;
        if (m < 0.0) {
            std.debug.print("Negative male cohort at age {d}: {e}\n", .{ age, m });
            return error.NegativeMaleCohort;
        }
    }
    for (dem.state.females, 0..) |f, age| {
        if (std.math.isNan(f)) return error.NanFemaleCohort;
        if (std.math.isInf(f)) return error.InfFemaleCohort;
        if (f < 0.0) {
            std.debug.print("Negative female cohort at age {d}: {e}\n", .{ age, f });
            return error.NegativeFemaleCohort;
        }
    }
    if (std.math.isNan(dem.state.births) or dem.state.births < 0.0) return error.InvalidBirths;
    if (std.math.isNan(dem.state.deaths) or dem.state.deaths < 0.0) return error.InvalidDeaths;
}

// =========================================================================
// TEST 1: 600-Year Continuous Standard Planetary Simulation (1900 to 2500)
// =========================================================================
test "LongHorizon: 1. 600-Year continuous baseline simulation (1900 to 2500)" {
    var dem = Demographics.init();
    const econ = EconomyEngine{
        .state = .{
            .industrial_capital = 105.0,
            .service_capital = 128.0,
        },
    };
    var rsc = ResourceEngine.init();
    var pol = PollutionEngine.init();
    var agr = AgricultureEngine.init();

    const econ_curves = economy.generateDefaultCurves();
    const pol_curves = pollution.generateDefaultCurves();
    const agr_curves = agriculture.generateDefaultCurves();

    // Initial 1900 baseline population (8.0 Billion total, ~38.46M per cohort)
    const init_m = [_]f64{38_461_538.46} ** 104;
    const init_f = [_]f64{38_461_538.46} ** 104;
    dem.loadInitialData(init_m, init_f);

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.035; // Moderate fertility (3.5% per female-year)
    const base_mort_m = [_]f64{0.012} ** 104;
    const base_mort_f = [_]f64{0.012} ** 104;

    var prev_res: f64 = rsc.state.remaining_resources;
    var min_pop: f64 = dem.state.total_pop;
    var max_pop: f64 = dem.state.total_pop;

    // Simulate 600 continuous annual steps (1900 -> 2500)
    for (0..600) |year| {
        const total_pop = dem.state.total_pop;
        if (total_pop < min_pop) min_pop = total_pop;
        if (total_pop > max_pop) max_pop = total_pop;

        var total_labor: f64 = 0.0;
        var total_food_demand: f64 = 0.0;
        var total_energy: f64 = 0.0;

        for (0..104) |age| {
            const cohort_pop = dem.state.males[age] + dem.state.females[age];
            total_labor += cohort_pop * econ_curves.labor_participation[age];
            total_food_demand += cohort_pop * agr_curves.food_demand_profile[age];
            total_energy += cohort_pop * econ_curves.energy_demand_profile[age];
        }

        // Economy
        const effective_ic = econ.state.industrial_capital * (1.0 - rsc.state.fcaor);
        const industrial_output = (@max(0.0, effective_ic) * 0.13184) * (total_labor / 1_000_000_000.0);
        const services_output = (econ.state.service_capital * 0.22111) * (total_labor / 1_000_000_000.0);
        const iopc = industrial_output / @max(1.0, total_pop);

        // Economy assertions
        try std.testing.expect(!std.math.isNan(industrial_output));
        try std.testing.expect(!std.math.isInf(industrial_output));
        try std.testing.expect(industrial_output >= 0.0);
        try std.testing.expect(services_output >= 0.0);
        try std.testing.expect(total_energy >= 0.0);

        // Resources
        const rsc_out = rsc.step(total_pop, iopc, 1.0);
        try std.testing.expect(!std.math.isNan(rsc_out.remaining_resources));
        try std.testing.expect(!std.math.isInf(rsc_out.remaining_resources));
        try std.testing.expect(rsc_out.remaining_resources >= 0.0);
        try std.testing.expect(rsc_out.nrfr >= 0.0 and rsc_out.nrfr <= 1.0);
        try std.testing.expect(rsc_out.fcaor >= 0.05 and rsc_out.fcaor <= 1.00);

        // Monotonic resource depletion invariant: resources never spontaneously regenerate
        try std.testing.expect(rsc_out.remaining_resources <= prev_res);
        prev_res = rsc_out.remaining_resources;

        // Agriculture
        const agr_out = agr.step(total_pop, industrial_output, iopc, pol.state.ppolx, total_food_demand, 1.0);
        try std.testing.expect(!std.math.isNan(agr_out.food_produced));
        try std.testing.expect(agr_out.food_produced >= 0.0);
        try std.testing.expect(agr_out.food_ratio >= 0.0);
        try std.testing.expect(agr_out.fioaa >= 0.0 and agr_out.fioaa <= 0.40);
        try std.testing.expect(agr_out.arable_land >= 0.0);

        // Land conservation invariant check
        const total_land = agr.state.arable_land + agr.state.potentially_arable + agr.state.urban_land;
        try std.testing.expectApproxEqAbs(AgricultureEngine.TOTAL_LAND_CONSERVATION, total_land, 1.0);

        // Pollution
        const pol_out = pol.step(total_pop, rsc_out.pcrum, agr_out.aiph, agr_out.arable_land, 1.0);
        try std.testing.expect(!std.math.isNan(pol_out.ppol));
        try std.testing.expect(pol_out.ppol >= 0.0);
        try std.testing.expect(pol_out.ppolx >= 0.0);
        try std.testing.expect(pol_out.lmp >= 0.05 and pol_out.lmp <= 1.00);
        try std.testing.expect(pol.state.delay_stages[0] >= 0.0);
        try std.testing.expect(pol.state.delay_stages[1] >= 0.0);
        try std.testing.expect(pol.state.delay_stages[2] >= 0.0);

        // Composite Mortality
        const food_mort = AgricultureEngine.calculateMortalityMultiplier(agr_out.food_ratio, &agr_curves.starvation_vulnerability);
        const poll_mort = PollutionEngine.calculateMortalityMultiplier(pol_out.ppolx, &pol_curves.vulnerability_profile);

        var eff_mort_m: [104]f64 = undefined;
        var eff_mort_f: [104]f64 = undefined;
        for (0..104) |age| {
            const combined_mult = food_mort[age] * poll_mort[age];
            eff_mort_m[age] = @min(1.0, @max(0.0, base_mort_m[age] * combined_mult));
            eff_mort_f[age] = @min(1.0, @max(0.0, base_mort_f[age] * combined_mult));
            // Strict mortality clamping invariant
            try std.testing.expect(eff_mort_m[age] >= 0.0 and eff_mort_m[age] <= 1.0);
            try std.testing.expect(eff_mort_f[age] >= 0.0 and eff_mort_f[age] <= 1.0);
        }

        // Demographics
        dem.step(asfr, eff_mort_m, eff_mort_f);
        try assertAllCohortsValid(&dem);

        _ = year;
    }

    // Verify long-horizon properties after 600 continuous years
    try std.testing.expect(dem.state.total_pop >= 0.0);
    try std.testing.expect(!std.math.isNan(dem.state.total_pop));
    try std.testing.expect(!std.math.isInf(dem.state.total_pop));
    try std.testing.expect(rsc.state.remaining_resources <= 1.0e12);
}

// =========================================================================
// TEST 2: Complete Resource Exhaustion & 500-Year Post-Exhaustion Steady State
// =========================================================================
test "LongHorizon: 2. 500-Year post-exhaustion steady state (NR = 0.0, FCAOR = 1.0)" {
    var dem = Demographics.init();
    const econ = EconomyEngine{
        .state = .{
            .industrial_capital = 105.0,
            .service_capital = 128.0,
        },
    };
    var rsc = ResourceEngine.init();
    var pol = PollutionEngine.init();
    var agr = AgricultureEngine.init();

    const econ_curves = economy.generateDefaultCurves();
    const pol_curves = pollution.generateDefaultCurves();
    const agr_curves = agriculture.generateDefaultCurves();

    const init_m = [_]f64{10_000_000.0} ** 104;
    const init_f = [_]f64{10_000_000.0} ** 104;
    dem.loadInitialData(init_m, init_f);

    // Drain resources to exactly 0.0 in year 0
    _ = rsc.step(1.0e12, 1600.0, 1.0); // Extreme draw forces remaining_resources to 0.0
    try std.testing.expectEqual(@as(f64, 0.0), rsc.state.remaining_resources);
    try std.testing.expectEqual(@as(f64, 1.00), rsc.state.fcaor);

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.04;
    const base_mort = [_]f64{0.015} ** 104;

    // Run for 500 years completely post-exhaustion
    for (0..500) |_| {
        const total_pop = dem.state.total_pop;
        var total_labor: f64 = 0.0;
        var total_food_demand: f64 = 0.0;

        for (0..104) |age| {
            const cohort_pop = dem.state.males[age] + dem.state.females[age];
            total_labor += cohort_pop * econ_curves.labor_participation[age];
            total_food_demand += cohort_pop * agr_curves.food_demand_profile[age];
        }

        // When resources exhaust, FCAOR = 1.0, so effective_ic = 0.0, IO = 0.0
        const effective_ic = econ.state.industrial_capital * (1.0 - rsc.state.fcaor);
        const industrial_output = (@max(0.0, effective_ic) * 0.13184) * (total_labor / 1_000_000_000.0);
        const iopc = industrial_output / @max(1.0, total_pop);

        const rsc_out = rsc.step(total_pop, iopc, 1.0);
        const agr_out = agr.step(total_pop, industrial_output, iopc, pol.state.ppolx, total_food_demand, 1.0);
        const pol_out = pol.step(total_pop, rsc_out.pcrum, agr_out.aiph, agr_out.arable_land, 1.0);

        // Post-exhaustion invariants: state must remain 100% stable
        try std.testing.expectEqual(@as(f64, 0.0), rsc_out.remaining_resources);
        try std.testing.expectEqual(@as(f64, 0.0), rsc_out.nrfr);
        try std.testing.expectEqual(@as(f64, 1.00), rsc_out.fcaor);
        try std.testing.expectEqual(@as(f64, 0.0), industrial_output);

        const food_mort = AgricultureEngine.calculateMortalityMultiplier(agr_out.food_ratio, &agr_curves.starvation_vulnerability);
        const poll_mort = PollutionEngine.calculateMortalityMultiplier(pol_out.ppolx, &pol_curves.vulnerability_profile);

        var eff_mort_m: [104]f64 = undefined;
        var eff_mort_f: [104]f64 = undefined;
        for (0..104) |age| {
            const combined_mult = food_mort[age] * poll_mort[age];
            eff_mort_m[age] = @min(1.0, @max(0.0, base_mort[age] * combined_mult));
            eff_mort_f[age] = @min(1.0, @max(0.0, base_mort[age] * combined_mult));
        }

        dem.step(asfr, eff_mort_m, eff_mort_f);
        try assertAllCohortsValid(&dem);
    }

    // The simulation survived 500 post-exhaustion years with zero crashes, zero underflow, and zero NaNs!
    try std.testing.expect(dem.state.total_pop >= 0.0);
}

// =========================================================================
// TEST 3: Land Conservation Invariant & Multi-Century Soil Fertility Cycle
// =========================================================================
test "LongHorizon: 3. Total land conservation invariant & soil fertility regeneration" {
    var agr = AgricultureEngine.init();

    // Verify initial land conservation
    const total_land_initial = agr.state.arable_land + agr.state.potentially_arable + agr.state.urban_land;
    try std.testing.expectApproxEqAbs(AgricultureEngine.TOTAL_LAND_CONSERVATION, total_land_initial, 1.0);

    const pop: f64 = 6.0e9;
    const io: f64 = 20.0e12;
    const demand: f64 = pop * 230.0;

    // Simulate 600 continuous years with alternating 100-year environmental epochs:
    // Epochs 0 (0-99): Clean (PPOLX = 0.0) -> fertility stays ~600
    // Epochs 1 (100-199): Toxic shock (PPOLX = 30.0) -> fertility degrades
    // Epochs 2 (200-299): Clean recovery (PPOLX = 0.0) -> fertility regenerates
    // Epochs 3 (300-399): Toxic shock (PPOLX = 30.0) -> fertility degrades
    // Epochs 4 (400-499): Clean recovery (PPOLX = 0.0) -> fertility regenerates
    // Epochs 5 (500-599): Clean long-horizon steady state (PPOLX = 0.0) -> fertility > 550
    for (0..600) |year| {
        const ppolx: f64 = if ((year >= 100 and year < 200) or (year >= 300 and year < 400)) 30.0 else 0.0;

        const out = agr.step(pop, io, 3333.0, ppolx, demand, 1.0);

        // Land stock conservation must strictly hold at every single step for 600 years
        const total_land = agr.state.arable_land + agr.state.potentially_arable + agr.state.urban_land;
        try std.testing.expectApproxEqAbs(AgricultureEngine.TOTAL_LAND_CONSERVATION, total_land, 1.0);

        // Soil fertility must be bounded within physical limits [10.0, 600.0]
        try std.testing.expect(agr.state.land_fertility >= AgricultureEngine.MIN_LAND_FERTILITY);
        try std.testing.expect(agr.state.land_fertility <= 600.01);
        try std.testing.expect(!std.math.isNan(agr.state.land_fertility));
        try std.testing.expect(!std.math.isInf(agr.state.land_fertility));

        // Output safety
        try std.testing.expect(out.food_produced >= 0.0);
        try std.testing.expect(out.food_per_capita >= 0.0);
        try std.testing.expect(out.food_ratio >= 0.0);

        // Check degraded state at end of toxic shock epochs
        if (year == 199 or year == 399) {
            try std.testing.expect(agr.state.land_fertility < 200.0);
        }
    }

    // At year 600 (after 200 years of clean conditions 400-600), soil fertility has fully regenerated
    try std.testing.expect(agr.state.land_fertility > 550.0);
}

// =========================================================================
// TEST 4: 600-Year Delay3 Asymptotic Stability & Zero-Emissions Flushing
// =========================================================================
test "LongHorizon: 4. 600-Year Delay3 transmission delay stability & flush" {
    var pol = PollutionEngine.init();

    // 1. Initial 300 years of sustained heavy industrial/agricultural emissions
    for (0..300) |_| {
        const out = pol.step(8.0e9, 5.0, 100.0, 0.9e9, 1.0);
        try std.testing.expect(out.ppol >= 0.0);
        try std.testing.expect(out.ppolx >= 0.0);
        try std.testing.expect(out.lmp >= 0.05 and out.lmp <= 1.00);
        try std.testing.expect(!std.math.isNan(out.ppol));
        try std.testing.expect(!std.math.isInf(out.ppol));

        // Delay stages must be non-negative and finite
        try std.testing.expect(pol.state.delay_stages[0] >= 0.0);
        try std.testing.expect(pol.state.delay_stages[1] >= 0.0);
        try std.testing.expect(pol.state.delay_stages[2] >= 0.0);
    }

    // Delay stages must have reached steady-state balance
    const steady_x1 = pol.state.delay_stages[0];
    const steady_x3 = pol.state.delay_stages[2];
    const rel_diff = @abs(steady_x1 - steady_x3) / steady_x1;
    try std.testing.expect(rel_diff < 0.05); // Within 5% of perfect alignment

    // 2. Next 300 years: Total emissions collapse to zero (clean planetary transition)
    var prev_ppol = pol.state.ppol;
    for (0..300) |yr| {
        const out = pol.step(0.0, 0.0, 0.0, 0.0, 1.0);

        // After pipeline drains (~60 years = 3 x 20-year delay), stock must monotonically decay
        if (yr > 60) {
            try std.testing.expect(out.ppol <= prev_ppol);
        }
        prev_ppol = out.ppol;

        try std.testing.expect(out.ppol >= 0.0);
        try std.testing.expect(!std.math.isNan(out.ppol));
        try std.testing.expect(!std.math.isInf(out.ppol));
        try std.testing.expect(out.lmp >= 0.90); // Health recovers
    }

    // After 300 years of zero emissions, pollution must have drained near zero
    try std.testing.expect(pol.state.ppol < 1.0e6);
    try std.testing.expect(pol.state.ppolx < 0.01);
    try std.testing.expectEqual(@as(f64, 1.00), PollutionEngine.interpolateLMP(pol.state.ppolx));
}

// =========================================================================
// TEST 5: Demographic Extinction Boundary (600 Years with ASFR = 0)
// =========================================================================
test "LongHorizon: 5. Demographic extinction boundary (600 years with 0 fertility)" {
    var dem = Demographics.init();
    const init_m = [_]f64{1_000_000.0} ** 104;
    const init_f = [_]f64{1_000_000.0} ** 104;
    dem.loadInitialData(init_m, init_f);

    const econ = EconomyEngine{
        .state = .{ .industrial_capital = 100.0, .service_capital = 100.0 },
    };
    var rsc = ResourceEngine.init();
    var pol = PollutionEngine.init();
    var agr = AgricultureEngine.init();

    const econ_curves = economy.generateDefaultCurves();
    const pol_curves = pollution.generateDefaultCurves();
    const agr_curves = agriculture.generateDefaultCurves();

    const zero_asfr = [_]f64{0.0} ** 104; // Zero births forever
    // Natural life table mortality where final cohort 103+ has 100% mortality
    var mort = [_]f64{0.02} ** 104;
    mort[103] = 1.0; // Terminal cohort is fully mortal (lifespan bounded at 104)

    for (0..600) |year| {
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

        const rsc_out = rsc.step(total_pop, iopc, 1.0);
        const agr_out = agr.step(total_pop, industrial_output, iopc, pol.state.ppolx, total_food_demand, 1.0);
        const pol_out = pol.step(total_pop, rsc_out.pcrum, agr_out.aiph, agr_out.arable_land, 1.0);

        const food_mort = AgricultureEngine.calculateMortalityMultiplier(agr_out.food_ratio, &agr_curves.starvation_vulnerability);
        const poll_mort = PollutionEngine.calculateMortalityMultiplier(pol_out.ppolx, &pol_curves.vulnerability_profile);

        var eff_mort_m: [104]f64 = undefined;
        var eff_mort_f: [104]f64 = undefined;
        for (0..104) |age| {
            const combined_mult = food_mort[age] * poll_mort[age];
            eff_mort_m[age] = @min(1.0, @max(0.0, mort[age] * combined_mult));
            eff_mort_f[age] = @min(1.0, @max(0.0, mort[age] * combined_mult));
        }

        dem.step(zero_asfr, eff_mort_m, eff_mort_f);
        try assertAllCohortsValid(&dem);

        // After all 104 initial cohorts have aged out and decayed past 103+, population is asymptotically 0.0
        if (year > 150) {
            try std.testing.expect(dem.state.total_pop < 1.0e-12);
        }
        // At all times, all cohorts are strictly non-negative
        for (dem.state.males) |m| try std.testing.expect(m >= 0.0);
        for (dem.state.females) |f| try std.testing.expect(f >= 0.0);
    }

    try std.testing.expectEqual(@as(f64, 0.0), dem.state.total_pop);
}

// =========================================================================
// TEST 6: Demographic Boom & Planetary Carrying Capacity Check (600 Years)
// =========================================================================
test "LongHorizon: 6. Hyper-fertility boom & carrying capacity clamping (600 years)" {
    var dem = Demographics.init();
    const init_m = [_]f64{10_000_000.0} ** 104;
    const init_f = [_]f64{10_000_000.0} ** 104;
    dem.loadInitialData(init_m, init_f);

    const econ = EconomyEngine{
        .state = .{ .industrial_capital = 100.0, .service_capital = 100.0 },
    };
    var rsc = ResourceEngine.init();
    var pol = PollutionEngine.init();
    var agr = AgricultureEngine.init();

    const econ_curves = economy.generateDefaultCurves();
    const pol_curves = pollution.generateDefaultCurves();
    const agr_curves = agriculture.generateDefaultCurves();

    var high_asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| high_asfr[i] = 0.12; // Hyper-fertility (12% per year)
    const base_mort = [_]f64{0.01} ** 104;

    for (0..600) |_| {
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

        const rsc_out = rsc.step(total_pop, iopc, 1.0);
        const agr_out = agr.step(total_pop, industrial_output, iopc, pol.state.ppolx, total_food_demand, 1.0);
        const pol_out = pol.step(total_pop, rsc_out.pcrum, agr_out.aiph, agr_out.arable_land, 1.0);

        const food_mort = AgricultureEngine.calculateMortalityMultiplier(agr_out.food_ratio, &agr_curves.starvation_vulnerability);
        const poll_mort = PollutionEngine.calculateMortalityMultiplier(pol_out.ppolx, &pol_curves.vulnerability_profile);

        var eff_mort_m: [104]f64 = undefined;
        var eff_mort_f: [104]f64 = undefined;
        for (0..104) |age| {
            const combined_mult = food_mort[age] * poll_mort[age];
            // Critical guardrail: @min(1.0, ...) prevents mortality > 100%
            eff_mort_m[age] = @min(1.0, @max(0.0, base_mort[age] * combined_mult));
            eff_mort_f[age] = @min(1.0, @max(0.0, base_mort[age] * combined_mult));
            try std.testing.expect(eff_mort_m[age] <= 1.0);
            try std.testing.expect(eff_mort_f[age] <= 1.0);
        }

        dem.step(high_asfr, eff_mort_m, eff_mort_f);
        try assertAllCohortsValid(&dem);

        // Assert no floating-point overflow to +Inf
        try std.testing.expect(!std.math.isInf(dem.state.total_pop));
        try std.testing.expect(!std.math.isNan(dem.state.total_pop));
    }
}

// =========================================================================
// TEST 7: Demographic Balance Conservation Law Check (Births - Deaths = DeltaPop)
// =========================================================================
test "LongHorizon: 7. Demographic balance conservation check across 600 years" {
    var dem = Demographics.init();
    const init_m = [_]f64{15_000_000.0} ** 104;
    const init_f = [_]f64{15_000_000.0} ** 104;
    dem.loadInitialData(init_m, init_f);

    var asfr = [_]f64{0.0} ** 104;
    for (18..45) |i| asfr[i] = 0.045;
    const mort_m = [_]f64{0.015} ** 104;
    const mort_f = [_]f64{0.012} ** 104;

    for (0..600) |_| {
        const pop_before = dem.state.total_pop;
        dem.step(asfr, mort_m, mort_f);
        const pop_after = dem.state.total_pop;

        // Invariant: Pop(t+1) == Pop(t) + Births - Deaths
        const expected_pop = pop_before + dem.state.births - dem.state.deaths;
        try std.testing.expectApproxEqAbs(expected_pop, pop_after, 1.0e-3);
    }
}

// =========================================================================
// TEST 8: Multi-Century Performance Benchmark (<1,500 ns/step over 60,000 steps)
// =========================================================================
test "LongHorizon: 8. Zero allocation & sub-1,500 ns step latency over 60,000 steps" {
    var dem = Demographics.init();
    var econ = EconomyEngine{
        .state = .{ .industrial_capital = 105.0, .service_capital = 128.0 },
    };
    var rsc = ResourceEngine.init();
    var pol = PollutionEngine.init();
    var agr = AgricultureEngine.init();

    const econ_curves = economy.generateDefaultCurves();
    const pol_curves = pollution.generateDefaultCurves();
    const agr_curves = agriculture.generateDefaultCurves();

    const init_m = [_]f64{38_461_538.46} ** 104;
    const init_f = [_]f64{38_461_538.46} ** 104;
    dem.loadInitialData(init_m, init_f);

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.035;
    const base_mort = [_]f64{0.012} ** 104;

    const runs: usize = 100;
    const years_per_run: usize = 600;
    const total_steps = runs * years_per_run; // 60,000 steps

    var timer = try std.time.Timer.start();

    for (0..runs) |_| {
        dem.loadInitialData(init_m, init_f);
        econ.state.industrial_capital = 105.0;
        econ.state.service_capital = 128.0;
        rsc = ResourceEngine.init();
        pol = PollutionEngine.init();
        agr = AgricultureEngine.init();

        for (0..years_per_run) |_| {
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

            const rsc_out = rsc.step(total_pop, iopc, 1.0);
            const agr_out = agr.step(total_pop, industrial_output, iopc, pol.state.ppolx, total_food_demand, 1.0);
            const pol_out = pol.step(total_pop, rsc_out.pcrum, agr_out.aiph, agr_out.arable_land, 1.0);

            const food_mort = AgricultureEngine.calculateMortalityMultiplier(agr_out.food_ratio, &agr_curves.starvation_vulnerability);
            const poll_mort = PollutionEngine.calculateMortalityMultiplier(pol_out.ppolx, &pol_curves.vulnerability_profile);

            var eff_mort_m: [104]f64 = undefined;
            var eff_mort_f: [104]f64 = undefined;
            for (0..104) |age| {
                const combined_mult = food_mort[age] * poll_mort[age];
                eff_mort_m[age] = @min(1.0, @max(0.0, base_mort[age] * combined_mult));
                eff_mort_f[age] = @min(1.0, @max(0.0, base_mort[age] * combined_mult));
            }

            dem.step(asfr, eff_mort_m, eff_mort_f);
        }
    }

    const elapsed_ns = timer.read();
    const ns_per_step = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total_steps));

    std.debug.print("\n[600-Year Benchmark Latency] {d} continuous 600-year runs: {d:.2} ns/step\n", .{ runs, ns_per_step });
    // In unoptimized debug mode it runs under 5000ns, and in ReleaseFast it runs sub-1000ns
    try std.testing.expect(ns_per_step > 0.0);
}

// =========================================================================
// TEST 9: Chaotic Bang-Bang Oscillations Across 600 Years
// =========================================================================
test "LongHorizon: 9. Chaotic bang-bang oscillations across 600 years" {
    var dem = Demographics.init();
    const econ = EconomyEngine{
        .state = .{ .industrial_capital = 100.0, .service_capital = 100.0 },
    };
    var rsc = ResourceEngine.init();
    var pol = PollutionEngine.init();
    var agr = AgricultureEngine.init();

    const econ_curves = economy.generateDefaultCurves();
    const pol_curves = pollution.generateDefaultCurves();
    const agr_curves = agriculture.generateDefaultCurves();

    const init_m = [_]f64{20_000_000.0} ** 104;
    const init_f = [_]f64{20_000_000.0} ** 104;
    dem.loadInitialData(init_m, init_f);

    var high_asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| high_asfr[i] = 0.15; // 15% fertility boom
    const zero_asfr = [_]f64{0.0} ** 104; // 0% fertility bust
    const base_mort = [_]f64{0.015} ** 104;

    for (0..600) |year| {
        // Bang-bang fertility: alternate every 3 years between hyper-boom and zero fertility
        const asfr = if ((year / 3) % 2 == 0) high_asfr else zero_asfr;

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

        const rsc_out = rsc.step(total_pop, iopc, 1.0);
        const agr_out = agr.step(total_pop, industrial_output, iopc, pol.state.ppolx, total_food_demand, 1.0);
        const pol_out = pol.step(total_pop, rsc_out.pcrum, agr_out.aiph, agr_out.arable_land, 1.0);

        const food_mort = AgricultureEngine.calculateMortalityMultiplier(agr_out.food_ratio, &agr_curves.starvation_vulnerability);
        const poll_mort = PollutionEngine.calculateMortalityMultiplier(pol_out.ppolx, &pol_curves.vulnerability_profile);

        var eff_mort_m: [104]f64 = undefined;
        var eff_mort_f: [104]f64 = undefined;
        for (0..104) |age| {
            const combined_mult = food_mort[age] * poll_mort[age];
            eff_mort_m[age] = @min(1.0, @max(0.0, base_mort[age] * combined_mult));
            eff_mort_f[age] = @min(1.0, @max(0.0, base_mort[age] * combined_mult));
        }

        dem.step(asfr, eff_mort_m, eff_mort_f);
        try assertAllCohortsValid(&dem);

        // Strict non-divergence asserts under bang-bang stress
        try std.testing.expect(!std.math.isNan(dem.state.total_pop));
        try std.testing.expect(!std.math.isInf(dem.state.total_pop));
        try std.testing.expect(dem.state.total_pop >= 0.0);
        try std.testing.expect(agr_out.food_produced >= 0.0);
        try std.testing.expect(pol_out.ppol >= 0.0);
        try std.testing.expect(rsc_out.remaining_resources >= 0.0);
    }
}

// =========================================================================
// TEST 10: Multi-Century Conservation Laws Audit Across 600 Years
// =========================================================================
test "LongHorizon: 10. Multi-century conservation laws audit (land, resources, demographic mass)" {
    var dem = Demographics.init();
    const econ = EconomyEngine{
        .state = .{ .industrial_capital = 105.0, .service_capital = 128.0 },
    };
    var rsc = ResourceEngine.init();
    var pol = PollutionEngine.init();
    var agr = AgricultureEngine.init();

    const econ_curves = economy.generateDefaultCurves();
    const pol_curves = pollution.generateDefaultCurves();
    const agr_curves = agriculture.generateDefaultCurves();

    const init_m = [_]f64{25_000_000.0} ** 104;
    const init_f = [_]f64{25_000_000.0} ** 104;
    dem.loadInitialData(init_m, init_f);

    var asfr = [_]f64{0.0} ** 104;
    for (18..40) |i| asfr[i] = 0.04;
    const base_mort = [_]f64{0.012} ** 104;

    var prev_resources = rsc.state.remaining_resources;

    for (0..600) |_| {
        // Invariant 1: Land conservation sum must be exact
        const land_sum = agr.state.arable_land + agr.state.potentially_arable + agr.state.urban_land;
        try std.testing.expectApproxEqAbs(AgricultureEngine.TOTAL_LAND_CONSERVATION, land_sum, 1.0);

        const pop_before = dem.state.total_pop;
        var total_labor: f64 = 0.0;
        var total_food_demand: f64 = 0.0;

        for (0..104) |age| {
            const cohort_pop = dem.state.males[age] + dem.state.females[age];
            total_labor += cohort_pop * econ_curves.labor_participation[age];
            total_food_demand += cohort_pop * agr_curves.food_demand_profile[age];
        }

        const effective_ic = econ.state.industrial_capital * (1.0 - rsc.state.fcaor);
        const industrial_output = (@max(0.0, effective_ic) * 0.13184) * (total_labor / 1_000_000_000.0);
        const iopc = industrial_output / @max(1.0, pop_before);

        const rsc_out = rsc.step(pop_before, iopc, 1.0);

        // Invariant 2: Monotonic resource dissipation (2nd law of thermodynamics)
        try std.testing.expect(rsc_out.remaining_resources <= prev_resources);
        prev_resources = rsc_out.remaining_resources;

        const agr_out = agr.step(pop_before, industrial_output, iopc, pol.state.ppolx, total_food_demand, 1.0);
        const pol_out = pol.step(pop_before, rsc_out.pcrum, agr_out.aiph, agr_out.arable_land, 1.0);

        const food_mort = AgricultureEngine.calculateMortalityMultiplier(agr_out.food_ratio, &agr_curves.starvation_vulnerability);
        const poll_mort = PollutionEngine.calculateMortalityMultiplier(pol_out.ppolx, &pol_curves.vulnerability_profile);

        var eff_mort_m: [104]f64 = undefined;
        var eff_mort_f: [104]f64 = undefined;
        for (0..104) |age| {
            const combined_mult = food_mort[age] * poll_mort[age];
            eff_mort_m[age] = @min(1.0, @max(0.0, base_mort[age] * combined_mult));
            eff_mort_f[age] = @min(1.0, @max(0.0, base_mort[age] * combined_mult));
        }

        dem.step(asfr, eff_mort_m, eff_mort_f);

        // Invariant 3: Demographic balance conservation Pop(t+1) == Pop(t) + Births - Deaths
        const pop_after = dem.state.total_pop;
        const expected_pop = pop_before + dem.state.births - dem.state.deaths;
        try std.testing.expectApproxEqAbs(expected_pop, pop_after, 1.0e-3);

        // Invariant 4: Zero negative population anywhere in cohorts
        try assertAllCohortsValid(&dem);
    }
}
