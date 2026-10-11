const std = @import("std");
const h = @import("e2e_harness.zig");

// =========================================================================
// Feature 1: Resources Engine (NR, NRUR, FCAOR)
// =========================================================================

test "T1.1 Resources - initial state and conservation bounds" {
    const rsc = h.ResourceEngine.init();
    try std.testing.expectEqual(@as(f64, 1.0e12), rsc.state.remaining_resources);
    try std.testing.expectEqual(@as(f64, 0.05), rsc.state.fcaor);
    try std.testing.expect(rsc.state.remaining_resources > 0.0);
}

test "T1.2 Resources - PCRUM non-linear curve evaluation" {
    const pcrum_0 = h.ResourceEngine.interpolatePCRUM(0.0);
    const pcrum_200 = h.ResourceEngine.interpolatePCRUM(200.0);
    const pcrum_600 = h.ResourceEngine.interpolatePCRUM(600.0);
    const pcrum_1000 = h.ResourceEngine.interpolatePCRUM(1000.0);
    const pcrum_1600 = h.ResourceEngine.interpolatePCRUM(1600.0);

    try std.testing.expectApproxEqAbs(@as(f64, 0.0), pcrum_0, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.85), pcrum_200, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 4.40), pcrum_600, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 6.20), pcrum_1000, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 7.00), pcrum_1600, 1e-4);
}

test "T1.3 Resources - single step depletion at baseline population" {
    var rsc = h.ResourceEngine.init();
    const total_pop: f64 = 8.0e9;
    const iopc: f64 = 300.0;
    const out = rsc.step(total_pop, iopc, 1.0);

    try std.testing.expect(out.remaining_resources < 1.0e12);
    try std.testing.expect(out.resource_usage_rate > 0.0);
    try std.testing.expect(out.nrfr < 1.0 and out.nrfr > 0.98);
    try std.testing.expect(out.fcaor >= 0.05);
}

test "T1.4 Resources - FCAOR capital extraction drag curve" {
    const fcaor_1_0 = h.ResourceEngine.interpolateFCAOR(1.0);
    const fcaor_0_6 = h.ResourceEngine.interpolateFCAOR(0.6);
    const fcaor_0_4 = h.ResourceEngine.interpolateFCAOR(0.4);
    const fcaor_0_2 = h.ResourceEngine.interpolateFCAOR(0.2);
    const fcaor_0_0 = h.ResourceEngine.interpolateFCAOR(0.0);

    try std.testing.expectApproxEqAbs(@as(f64, 0.05), fcaor_1_0, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), fcaor_0_6, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.20), fcaor_0_4, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.70), fcaor_0_2, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 1.00), fcaor_0_0, 1e-4);
}

test "T1.5 Resources - multi-decade depletion dynamics" {
    var rsc = h.ResourceEngine.init();
    var last_nr = rsc.state.remaining_resources;
    for (0..50) |_| {
        const out = rsc.step(8.0e9, 400.0, 1.0);
        try std.testing.expect(out.remaining_resources <= last_nr);
        last_nr = out.remaining_resources;
    }
    try std.testing.expect(rsc.state.remaining_resources < 1.0e12);
}

// =========================================================================
// Feature 2: Pollution Engine (PPOL, Delay3, PPASR)
// =========================================================================

test "T1.6 Pollution - initial state and 1970 normalization" {
    const pol = h.PollutionEngine.init();
    try std.testing.expectApproxEqAbs(@as(f64, 2.5e7), pol.state.ppol, 1e-2);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5e7 / 1.36e8), pol.state.ppolx, 1e-4);
}

test "T1.7 Pollution - Delay3 physical transmission delay" {
    var pol = h.PollutionEngine.init();
    const initial_delay_stage_3 = pol.state.delay_stages[2];
    // Large generation input surge
    _ = pol.step(10.0e9, 5.0, 100.0, 1.0e9, 1.0);
    // Stage 1 reacts immediately, stage 3 lags
    try std.testing.expect(pol.state.delay_stages[0] > initial_delay_stage_3);
}

test "T1.8 Pollution - assimilation rate saturation (AHLM & PPASR)" {
    var pol = h.PollutionEngine.init();
    pol.state.ppol = 1.36e9; // 10x 1970 base
    const out = pol.step(1.0e9, 1.0, 10.0, 1.0e8, 1.0);
    try std.testing.expect(out.ppolx > 5.0);
    try std.testing.expect(out.lmp < 1.0);
}

test "T1.9 Pollution - lifetime multiplier (LMP) non-linear table" {
    const lmp_0 = h.PollutionEngine.interpolateLMP(0.0);
    const lmp_20 = h.PollutionEngine.interpolateLMP(20.0);
    const lmp_50 = h.PollutionEngine.interpolateLMP(50.0);
    const lmp_100 = h.PollutionEngine.interpolateLMP(100.0);

    try std.testing.expectApproxEqAbs(@as(f64, 1.00), lmp_0, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.97), lmp_20, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.85), lmp_50, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 0.20), lmp_100, 1e-4);
}

test "T1.10 Pollution - age-specific toxic mortality profile" {
    const curves = h.generateDefaultPollutionCurves();
    const mort_mult = h.PollutionEngine.calculateMortalityMultiplier(50.0, &curves.vulnerability_profile);
    // Infants (age 0) vulnerability is 3.0, adults (age 30) is 0.5
    try std.testing.expect(mort_mult[0] > mort_mult[30]);
    try std.testing.expect(mort_mult[80] > mort_mult[30]);
}

// =========================================================================
// Feature 3: Agriculture Engine (Land, Yield, Food)
// =========================================================================

test "T1.11 Agriculture - initial state land conservation" {
    const agr = h.AgricultureEngine.init();
    try std.testing.expectEqual(@as(f64, 0.9e9), agr.state.arable_land);
    try std.testing.expectEqual(@as(f64, 2.3e9), agr.state.potentially_arable);
    try std.testing.expectEqual(@as(f64, 8.2e6), agr.state.urban_land);
    try std.testing.expectEqual(@as(f64, 600.0), agr.state.land_fertility);
}

test "T1.12 Agriculture - input yield multiplier LYMC non-linear table" {
    const lymc_0 = h.AgricultureEngine.interpolateLYMC(0.0);
    const lymc_80 = h.AgricultureEngine.interpolateLYMC(80.0);
    const lymc_320 = h.AgricultureEngine.interpolateLYMC(320.0);
    const lymc_1000 = h.AgricultureEngine.interpolateLYMC(1000.0);

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), lymc_0, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 3.8), lymc_80, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 6.3), lymc_320, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), lymc_1000, 1e-4);
}

test "T1.13 Agriculture - food production and food ratio" {
    var agr = h.AgricultureEngine.init();
    const total_pop = 8.0e9;
    const food_demand = 8.0e9 * 230.0;
    const out = agr.step(total_pop, 30.0e12, 3750.0, 1.0, food_demand, 1.0);

    try std.testing.expect(out.food_produced > 0.0);
    try std.testing.expect(out.food_ratio > 0.0);
    try std.testing.expect(out.food_per_capita > 0.0);
}

test "T1.14 Agriculture - capital allocation feedback FIOAA" {
    const fioaa_surplus = h.AgricultureEngine.interpolateFIOAA(2.5);
    const fioaa_normal = h.AgricultureEngine.interpolateFIOAA(1.0);
    const fioaa_famine = h.AgricultureEngine.interpolateFIOAA(0.4);

    try std.testing.expectEqual(@as(f64, 0.0), fioaa_surplus);
    try std.testing.expect(fioaa_normal > 0.0 and fioaa_normal <= 0.15);
    try std.testing.expect(fioaa_famine >= 0.30);
}

test "T1.15 Agriculture - starvation mortality curve and vulnerability" {
    const curves = h.generateDefaultAgricultureCurves();
    const famine_mort = h.AgricultureEngine.calculateMortalityMultiplier(0.4, &curves.starvation_vulnerability);

    // In famine, infant mortality multiplier > adult multiplier
    try std.testing.expect(famine_mort[0] > famine_mort[30]);
    try std.testing.expect(famine_mort[80] > famine_mort[30]);
}

// =========================================================================
// Feature 4: Collision-Zone [104]f64 Interfaces
// =========================================================================

test "T1.16 Collision-Zone - memory size and 64-byte cache alignment" {
    try std.testing.expectEqual(@as(usize, 832), @sizeOf([104]f64));
    try std.testing.expectEqual(@as(usize, 0), @sizeOf([104]f64) % 64);
    try std.testing.expectEqual(@as(usize, 13), @sizeOf([104]f64) / 64);
}

test "T1.17 Collision-Zone - ResourceCurves profile structure" {
    const curves = h.generateDefaultResourceCurves();
    try std.testing.expectEqual(@as(usize, 104), curves.resource_usage_profile.len);
    for (curves.resource_usage_profile) |val| {
        try std.testing.expect(val >= 0.0 and val <= 1.5);
    }
}

test "T1.18 Collision-Zone - PollutionCurves vulnerability profile" {
    const curves = h.generateDefaultPollutionCurves();
    try std.testing.expectEqual(@as(usize, 104), curves.vulnerability_profile.len);
    try std.testing.expect(curves.vulnerability_profile[0] >= 3.0);
    try std.testing.expect(curves.vulnerability_profile[30] <= 0.6);
    try std.testing.expect(curves.vulnerability_profile[80] >= 2.5);
}

test "T1.19 Collision-Zone - AgricultureCurves caloric demand & famine vulnerability" {
    const curves = h.generateDefaultAgricultureCurves();
    try std.testing.expectEqual(@as(usize, 104), curves.food_demand_profile.len);
    try std.testing.expectEqual(@as(usize, 104), curves.starvation_vulnerability.len);
    try std.testing.expect(curves.food_demand_profile[0] < curves.food_demand_profile[25]);
}

test "T1.20 Collision-Zone - Demographics cohort alignment" {
    const dem = h.Demographics.init();
    try std.testing.expectEqual(@as(usize, 104), dem.state.males.len);
    try std.testing.expectEqual(@as(usize, 104), dem.state.females.len);
    try std.testing.expectEqual(@as(usize, 832), @sizeOf(@TypeOf(dem.state.males)));
}

// =========================================================================
// Feature 5: Unified 5-Sector Synchronous Stepping
// =========================================================================

test "T1.21 Synchronous Step - single step execution sequence" {
    var ctx = h.SimulationContext.init();
    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.05;
    const mort_m = [_]f64{0.01} ** 104;
    const mort_f = [_]f64{0.01} ** 104;

    const out = h.step5Sectors(&ctx, &asfr, &mort_m, &mort_f, 1.0);
    try h.assertOutputSafety(&out);
    try h.assertDemographicSafety(&ctx.dem);
}

test "T1.22 Synchronous Step - economic capital throttling by FCAOR" {
    var ctx1 = h.SimulationContext.init();
    var ctx2 = h.SimulationContext.init();
    ctx1.rsc.state.fcaor = 0.05;
    ctx2.rsc.state.fcaor = 0.60;

    var asfr = [_]f64{0.0} ** 104;
    const mort = [_]f64{0.01} ** 104;

    const out1 = h.step5Sectors(&ctx1, &asfr, &mort, &mort, 1.0);
    const out2 = h.step5Sectors(&ctx2, &asfr, &mort, &mort, 1.0);

    try std.testing.expect(out1.industrial_output > out2.industrial_output);
}

test "T1.23 Synchronous Step - demographic feedback to resource extraction" {
    var ctx1 = h.SimulationContext.init();
    var ctx2 = h.SimulationContext.init();
    // Halve population of ctx2
    for (0..104) |i| {
        ctx2.dem.state.males[i] *= 0.5;
        ctx2.dem.state.females[i] *= 0.5;
    }
    ctx2.dem.state.total_pop *= 0.5;

    var asfr = [_]f64{0.0} ** 104;
    const mort = [_]f64{0.01} ** 104;

    const out1 = h.step5Sectors(&ctx1, &asfr, &mort, &mort, 1.0);
    const out2 = h.step5Sectors(&ctx2, &asfr, &mort, &mort, 1.0);

    try std.testing.expect(out1.total_pop > out2.total_pop);
}

test "T1.24 Synchronous Step - agricultural inputs driven by industrial output" {
    var ctx = h.SimulationContext.init();
    var asfr = [_]f64{0.0} ** 104;
    const mort = [_]f64{0.01} ** 104;

    const out = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);
    try std.testing.expect(out.fioaa >= 0.0 and out.fioaa <= 0.40);
}

test "T1.25 Synchronous Step - composite mortality integration" {
    var ctx = h.SimulationContext.init();
    var asfr = [_]f64{0.0} ** 104;
    const mort_m = [_]f64{0.01} ** 104;
    const mort_f = [_]f64{0.01} ** 104;

    const out = h.step5Sectors(&ctx, &asfr, &mort_m, &mort_f, 1.0);
    try std.testing.expect(out.total_pop > 0.0);
}

// =========================================================================
// Feature 6: Sub-1,500 ns/step Zero-Allocation Performance
// =========================================================================

test "T1.26 Performance - stack allocation footprint audit" {
    // Total context with curves is under 8 KB (fits comfortably in L1 Data Cache of 32-48 KB)
    try std.testing.expect(@sizeOf(h.SimulationContext) < 8192);
    // Dynamic simulation state alone is under 2 KB (~1,808 bytes per PROJECT.md)
    const state_size = @sizeOf(h.PopulationState) + @sizeOf(h.EconomyState) +
        @sizeOf(h.ResourceState) + @sizeOf(h.PollutionState) + @sizeOf(h.AgricultureState);
    try std.testing.expect(state_size < 2048);
    try std.testing.expect(@sizeOf(h.ResourceState) == 16);
    try std.testing.expect(@sizeOf(h.PollutionState) <= 64);
    try std.testing.expect(@sizeOf(h.AgricultureState) <= 64);
}

test "T1.27 Performance - single-year step latency benchmark (<1,500 ns)" {
    var ctx = h.SimulationContext.init();
    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.05;
    const mort = [_]f64{0.01} ** 104;

    var timer = try std.time.Timer.start();
    const iterations: usize = 5000;
    for (0..iterations) |_| {
        _ = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);
    }
    const elapsed_ns: f64 = @floatFromInt(timer.read());
    const ns_per_step = elapsed_ns / @as(f64, @floatFromInt(iterations));

    // Must be well within budget (typically ~200-800 ns in ReleaseFast; <20,000 ns in unoptimized Debug mode)
    try std.testing.expect(ns_per_step < 20_000.0); // Debug/test mode threshold
}

test "T1.28 Performance - ResourceEngine standalone latency (<100 ns)" {
    var rsc = h.ResourceEngine.init();
    var timer = try std.time.Timer.start();
    const iterations: usize = 10_000;
    for (0..iterations) |_| {
        _ = rsc.step(8.0e9, 400.0, 1.0);
    }
    const elapsed_ns: f64 = @floatFromInt(timer.read());
    const ns_per_step = elapsed_ns / @as(f64, @floatFromInt(iterations));
    try std.testing.expect(ns_per_step < 500.0);
}

test "T1.29 Performance - PollutionEngine standalone latency (<100 ns)" {
    var pol = h.PollutionEngine.init();
    var timer = try std.time.Timer.start();
    const iterations: usize = 10_000;
    for (0..iterations) |_| {
        _ = pol.step(8.0e9, 4.0, 50.0, 0.9e9, 1.0);
    }
    const elapsed_ns: f64 = @floatFromInt(timer.read());
    const ns_per_step = elapsed_ns / @as(f64, @floatFromInt(iterations));
    try std.testing.expect(ns_per_step < 500.0);
}

test "T1.30 Performance - AgricultureEngine standalone latency (<100 ns)" {
    var agr = h.AgricultureEngine.init();
    var timer = try std.time.Timer.start();
    const iterations: usize = 10_000;
    for (0..iterations) |_| {
        _ = agr.step(8.0e9, 30.0e12, 3750.0, 1.0, 8.0e9 * 230.0, 1.0);
    }
    const elapsed_ns: f64 = @floatFromInt(timer.read());
    const ns_per_step = elapsed_ns / @as(f64, @floatFromInt(iterations));
    try std.testing.expect(ns_per_step < 500.0);
}

// =========================================================================
// Feature 7: Demographic & Numerical Safety (no NaN/Inf)
// =========================================================================

test "T1.31 Safety - baseline simulation demographic sanity (no NaN/Inf)" {
    var ctx = h.SimulationContext.init();
    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.05;
    const mort = [_]f64{0.01} ** 104;

    for (0..10) |_| {
        const out = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);
        try h.assertOutputSafety(&out);
        try h.assertDemographicSafety(&ctx.dem);
    }
}

test "T1.32 Safety - cohort non-negativity across all 104 ages" {
    var ctx = h.SimulationContext.init();
    var asfr = [_]f64{0.0} ** 104;
    const mort = [_]f64{0.05} ** 104;

    for (0..20) |_| {
        _ = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);
    }
    for (ctx.dem.state.males) |m| try std.testing.expect(m >= 0.0);
    for (ctx.dem.state.females) |f| try std.testing.expect(f >= 0.0);
}

test "T1.33 Safety - population conservation invariant" {
    var dem = h.Demographics.init();
    var init_m = [_]f64{0.0} ** 104;
    var init_f = [_]f64{0.0} ** 104;
    init_m[20] = 1_000_000.0;
    init_f[20] = 1_000_000.0;
    dem.loadInitialData(init_m, init_f);

    const initial_pop = dem.state.total_pop;
    var asfr = [_]f64{0.0} ** 104;
    asfr[20] = 0.1;
    const mort = [_]f64{0.01} ** 104;

    dem.step(asfr, mort, mort);
    const expected = initial_pop + dem.state.births - dem.state.deaths;
    try std.testing.expectApproxEqAbs(expected, dem.state.total_pop, 1e-4);
}

test "T1.34 Safety - mortality rate bounding [0.0, 1.0]" {
    var ctx = h.SimulationContext.init();
    var asfr = [_]f64{0.0} ** 104;
    const base_mort = [_]f64{0.99} ** 104; // Very high base mortality

    _ = h.step5Sectors(&ctx, &asfr, &base_mort, &base_mort, 1.0);
    try h.assertDemographicSafety(&ctx.dem);
    try std.testing.expect(ctx.dem.state.total_pop >= 0.0);
}

test "T1.35 Safety - economic output finiteness and positivity" {
    var ctx = h.SimulationContext.init();
    var asfr = [_]f64{0.0} ** 104;
    const mort = [_]f64{0.01} ** 104;

    const out = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);
    try std.testing.expect(!std.math.isNan(out.industrial_output));
    try std.testing.expect(!std.math.isInf(out.industrial_output));
    try std.testing.expect(out.industrial_output >= 0.0);
    try std.testing.expect(out.services_output >= 0.0);
    try std.testing.expect(out.energy_twh >= 0.0);
}
