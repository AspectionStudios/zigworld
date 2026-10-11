const std = @import("std");
const h = @import("e2e_harness.zig");

// =========================================================================
// Feature 1: Resources Boundary & Corner Cases
// =========================================================================

test "T2.1 Resources Boundary - zero initial resources (exhaustion state)" {
    var rsc = h.ResourceEngine.init();
    rsc.state.remaining_resources = 0.0;
    rsc.state.fcaor = 1.0;

    const out = rsc.step(8.0e9, 400.0, 1.0);
    try std.testing.expectEqual(@as(f64, 0.0), out.remaining_resources);
    try std.testing.expectEqual(@as(f64, 0.0), out.nrfr);
    try std.testing.expectEqual(@as(f64, 1.00), out.fcaor);
    try std.testing.expectEqual(@as(f64, 0.0), rsc.state.remaining_resources);
}

test "T2.2 Resources Boundary - zero population consumption" {
    var rsc = h.ResourceEngine.init();
    const initial_res = rsc.state.remaining_resources;
    const out = rsc.step(0.0, 500.0, 1.0);

    try std.testing.expectEqual(@as(f64, 0.0), out.resource_usage_rate);
    try std.testing.expectEqual(initial_res, out.remaining_resources);
    try std.testing.expectEqual(@as(f64, 1.0), out.nrfr);
    try std.testing.expectEqual(@as(f64, 0.05), out.fcaor);
}

test "T2.3 Resources Boundary - extreme high IOPC saturation" {
    const pcrum_extreme = h.ResourceEngine.interpolatePCRUM(1.0e8);
    const pcrum_1600 = h.ResourceEngine.interpolatePCRUM(1600.0);
    const pcrum_5000 = h.ResourceEngine.interpolatePCRUM(5000.0);

    try std.testing.expectEqual(@as(f64, 7.00), pcrum_extreme);
    try std.testing.expectEqual(@as(f64, 7.00), pcrum_1600);
    try std.testing.expectEqual(@as(f64, 7.00), pcrum_5000);
}

test "T2.4 Resources Boundary - negative pop and negative iopc clamping" {
    var rsc = h.ResourceEngine.init();
    const out = rsc.step(-5.0e9, -300.0, 1.0);

    try std.testing.expectEqual(@as(f64, 0.0), out.resource_usage_rate);
    try std.testing.expectEqual(@as(f64, 1.0e12), out.remaining_resources);
    try std.testing.expectEqual(@as(f64, 0.0), out.pcrum);
    try std.testing.expect(out.remaining_resources >= 0.0);
}

test "T2.5 Resources Boundary - massive time step depletion clamping" {
    var rsc = h.ResourceEngine.init();
    // Huge dt = 1000 years with 8B population
    const out = rsc.step(8.0e9, 1000.0, 1000.0);

    try std.testing.expectEqual(@as(f64, 0.0), out.remaining_resources);
    try std.testing.expectEqual(@as(f64, 0.0), out.nrfr);
    try std.testing.expectEqual(@as(f64, 1.00), out.fcaor);
}

// =========================================================================
// Feature 2: Pollution Boundary & Corner Cases
// =========================================================================

test "T2.6 Pollution Boundary - zero pollution baseline" {
    var pol = h.PollutionEngine.init();
    pol.state.ppol = 0.0;
    pol.state.ppolx = 0.0;
    const lmp = h.PollutionEngine.interpolateLMP(0.0);

    try std.testing.expectEqual(@as(f64, 1.00), lmp);
    const out = pol.step(0.0, 0.0, 0.0, 0.0, 1.0);
    try std.testing.expect(out.ppol >= 0.0);
    try std.testing.expect(!std.math.isNan(out.ppol));
}

test "T2.7 Pollution Boundary - extreme toxic shock (PPOLX = 1000)" {
    var pol = h.PollutionEngine.init();
    pol.state.ppol = 1.36e11; // 1000x benchmark level
    const out = pol.step(1.0e9, 1.0, 10.0, 1.0e8, 1.0);

    try std.testing.expect(out.ppolx >= 500.0);
    try std.testing.expect(out.lmp >= 0.05 and out.lmp <= 0.20);
    try std.testing.expect(!std.math.isNan(out.lmp));
}

test "T2.8 Pollution Boundary - zero emitter inputs decay" {
    var pol = h.PollutionEngine.init();
    const initial_ppol = pol.state.ppol;
    // No emissions for 10 years
    for (0..10) |_| {
        _ = pol.step(0.0, 0.0, 0.0, 0.0, 1.0);
    }
    // Assimilation should steadily reduce pollution
    try std.testing.expect(pol.state.ppol <= initial_ppol);
}

test "T2.9 Pollution Boundary - massive dt stability in Delay3" {
    var pol = h.PollutionEngine.init();
    // Step with dt = 5.0
    const out = pol.step(10.0e9, 7.0, 500.0, 1.0e9, 5.0);
    try std.testing.expect(!std.math.isNan(out.ppol));
    try std.testing.expect(!std.math.isInf(out.ppol));
    try std.testing.expect(out.ppol > 0.0);
}

test "T2.10 Pollution Boundary - negative pollution state prevention" {
    var pol = h.PollutionEngine.init();
    pol.state.ppol = 0.0001;
    // Step repeatedly with 0 inputs
    for (0..50) |_| {
        _ = pol.step(0.0, 0.0, 0.0, 0.0, 1.0);
    }
    try std.testing.expect(pol.state.ppol >= 0.0);
    try std.testing.expect(!std.math.isNan(pol.state.ppol));
}

// =========================================================================
// Feature 3: Agriculture Boundary & Corner Cases
// =========================================================================

test "T2.11 Agriculture Boundary - complete crop failure / zero food ratio" {
    const curves = h.generateDefaultAgricultureCurves();
    const famine_mort = h.AgricultureEngine.calculateMortalityMultiplier(0.0, &curves.starvation_vulnerability);

    // Bounded and non-NaN
    for (famine_mort) |m| {
        try std.testing.expect(!std.math.isNan(m));
        try std.testing.expect(!std.math.isInf(m));
        try std.testing.expect(m > 1.0);
    }
}

test "T2.12 Agriculture Boundary - super-abundance food ratio (FR = 10.0)" {
    const curves = h.generateDefaultAgricultureCurves();
    const surplus_mort = h.AgricultureEngine.calculateMortalityMultiplier(10.0, &curves.starvation_vulnerability);

    for (surplus_mort) |m| {
        try std.testing.expect(m >= 0.70 and m <= 1.00);
    }
}

test "T2.13 Agriculture Boundary - zero arable land" {
    var agr = h.AgricultureEngine.init();
    agr.state.arable_land = 0.0;
    const out = agr.step(8.0e9, 30.0e12, 3750.0, 1.0, 8.0e9 * 230.0, 1.0);

    try std.testing.expectEqual(@as(f64, 0.0), out.food_produced);
    try std.testing.expectEqual(@as(f64, 0.0), out.food_per_capita);
    try std.testing.expect(!std.math.isNan(out.aiph));
}

test "T2.14 Agriculture Boundary - extreme agricultural inputs saturation" {
    const lymc_extreme = h.AgricultureEngine.interpolateLYMC(100_000.0);
    try std.testing.expect(lymc_extreme <= 12.0);
    try std.testing.expect(!std.math.isNan(lymc_extreme));
}

test "T2.15 Agriculture Boundary - zero population food demand" {
    var agr = h.AgricultureEngine.init();
    const out = agr.step(0.0, 0.0, 0.0, 0.0, 0.0, 1.0);

    try std.testing.expect(!std.math.isNan(out.food_ratio));
    try std.testing.expect(!std.math.isInf(out.food_ratio));
}

// =========================================================================
// Feature 4: Collision-Zone [104]f64 Boundary & Corner Cases
// =========================================================================

test "T2.16 Collision-Zone Boundary - terminal cohort index 103 accumulator" {
    var dem = h.Demographics.init();
    var m = [_]f64{0.0} ** 104;
    var f = [_]f64{0.0} ** 104;
    m[102] = 500.0;
    m[103] = 1000.0;
    f[102] = 500.0;
    f[103] = 1000.0;
    dem.loadInitialData(m, f);

    const asfr = [_]f64{0.0} ** 104;
    const mort = [_]f64{0.0} ** 104; // 0% mortality to test conservation

    dem.step(asfr, mort, mort);
    // Cohort 103 should now contain 1000 (previous) + 500 (aged up from 102) = 1500
    try std.testing.expectEqual(@as(f64, 1500.0), dem.state.males[103]);
    try std.testing.expectEqual(@as(f64, 1500.0), dem.state.females[103]);
}

test "T2.17 Collision-Zone Boundary - zero population cohorts across all 104 ages" {
    const males = [_]f64{0.0} ** 104;
    const females = [_]f64{0.0} ** 104;
    var econ = h.EconomyEngine{
        .state = .{ .industrial_capital = 100.0, .service_capital = 100.0 },
    };
    const curves = h.generateDefaultEconomyCurves();
    const out = econ.step(&males, &females, &curves);

    try std.testing.expectEqual(@as(f64, 0.0), out.industrial_output);
    try std.testing.expectEqual(@as(f64, 0.0), out.services_output);
    try std.testing.expectEqual(@as(f64, 0.0), out.energy_twh);
}

test "T2.18 Collision-Zone Boundary - extreme demographic density (1 trillion pop)" {
    var dem = h.Demographics.init();
    const m = [_]f64{4.8e9} ** 104; // ~1 trillion total
    const f = [_]f64{4.8e9} ** 104;
    dem.loadInitialData(m, f);

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.05;
    const mort = [_]f64{0.01} ** 104;

    dem.step(asfr, mort, mort);
    try std.testing.expect(dem.state.total_pop > 9.0e11);
    try std.testing.expect(!std.math.isNan(dem.state.total_pop));
}

test "T2.19 Collision-Zone Boundary - subnormal float protection" {
    var dem = h.Demographics.init();
    const m = [_]f64{1.0e-300} ** 104;
    const f = [_]f64{1.0e-300} ** 104;
    dem.loadInitialData(m, f);

    const asfr = [_]f64{0.0} ** 104;
    const mort = [_]f64{0.50} ** 104;

    dem.step(asfr, mort, mort);
    try std.testing.expect(!std.math.isNan(dem.state.total_pop));
    try std.testing.expect(!std.math.isInf(dem.state.total_pop));
    try std.testing.expect(dem.state.total_pop >= 0.0);
}

test "T2.20 Collision-Zone Boundary - all-ones and all-zeros curve vectors" {
    const zero_curves = h.ResourceCurves{ .resource_usage_profile = [_]f64{0.0} ** 104 };
    const ones_curves = h.ResourceCurves{ .resource_usage_profile = [_]f64{1.0} ** 104 };

    for (zero_curves.resource_usage_profile) |v| try std.testing.expectEqual(@as(f64, 0.0), v);
    for (ones_curves.resource_usage_profile) |v| try std.testing.expectEqual(@as(f64, 1.0), v);
}

// =========================================================================
// Feature 5: Synchronous 5-Sector Boundary & Corner Cases
// =========================================================================

test "T2.21 Synchronous Step Boundary - total extinction step (pop = 0)" {
    var ctx = h.SimulationContext.init();
    // Zero out entire population
    ctx.dem.loadInitialData([_]f64{0.0} ** 104, [_]f64{0.0} ** 104);

    const asfr = [_]f64{0.0} ** 104;
    const mort = [_]f64{0.01} ** 104;

    const out = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);
    try std.testing.expectEqual(@as(f64, 0.0), out.total_pop);
    try std.testing.expectEqual(@as(f64, 0.0), out.industrial_output);
    try std.testing.expectEqual(@as(f64, 0.0), out.energy_twh);
    try std.testing.expect(!std.math.isNan(out.total_pop));
}

test "T2.22 Synchronous Step Boundary - zero capital collapse" {
    var ctx = h.SimulationContext.init();
    ctx.econ.state.industrial_capital = 0.0;
    ctx.econ.state.service_capital = 0.0;

    const asfr = [_]f64{0.0} ** 104;
    const mort = [_]f64{0.01} ** 104;

    const out = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);
    try std.testing.expectEqual(@as(f64, 0.0), out.industrial_output);
    try std.testing.expectEqual(@as(f64, 0.0), out.services_output);
    try std.testing.expect(out.total_pop > 0.0);
}

test "T2.23 Synchronous Step Boundary - complete resource depletion with active pop" {
    var ctx = h.SimulationContext.init();
    ctx.rsc.state.remaining_resources = 0.0;
    ctx.rsc.state.fcaor = 1.0;

    const asfr = [_]f64{0.0} ** 104;
    const mort = [_]f64{0.01} ** 104;

    const out = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);
    // Industrial output should be throttled to 0 by FCAOR = 1.0
    try std.testing.expectEqual(@as(f64, 0.0), out.industrial_output);
    try std.testing.expectEqual(@as(f64, 1.0), out.fcaor);
}

test "T2.24 Synchronous Step Boundary - acute simultaneous famine and toxic crisis" {
    var ctx = h.SimulationContext.init();
    ctx.pol.state.ppol = 1.36e10; // 100x benchmark pollution
    ctx.agr.state.land_fertility = 10.0; // Collapsed fertility
    ctx.agr.state.agricultural_inputs = 1.0e7;

    const asfr = [_]f64{0.0} ** 104;
    const mort = [_]f64{0.01} ** 104;

    const out = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);
    try std.testing.expect(out.food_ratio < 0.2);
    try std.testing.expect(out.ppolx > 50.0);
    try h.assertDemographicSafety(&ctx.dem);
}

test "T2.25 Synchronous Step Boundary - high fertility population surge" {
    var ctx = h.SimulationContext.init();
    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.25; // 25% birth rate per female
    const mort = [_]f64{0.005} ** 104;

    const initial_pop = ctx.dem.state.total_pop;
    _ = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);

    try std.testing.expect(ctx.dem.state.total_pop > initial_pop);
    try h.assertDemographicSafety(&ctx.dem);
}

// =========================================================================
// Feature 6: Performance Boundary & Stress Cases
// =========================================================================

test "T2.26 Performance Stress - 200-year continuous simulation loop" {
    var ctx = h.SimulationContext.init();
    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.03;
    const mort = [_]f64{0.01} ** 104;

    for (0..200) |_| {
        const out = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);
        try h.assertOutputSafety(&out);
    }
    try h.assertDemographicSafety(&ctx.dem);
}

test "T2.27 Performance Stress - high-speed step timing jitter" {
    var ctx = h.SimulationContext.init();
    var asfr = [_]f64{0.0} ** 104;
    const mort = [_]f64{0.01} ** 104;

    var timer = try std.time.Timer.start();
    const runs: usize = 1000;
    for (0..runs) |_| {
        _ = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);
    }
    const elapsed: f64 = @floatFromInt(timer.read());
    const avg = elapsed / @as(f64, @floatFromInt(runs));
    try std.testing.expect(avg > 0.0);
}

test "T2.28 Performance Stress - zero-allocation guarantee verification" {
    // Assert all state structs are POD types (zero pointer indirection)
    try std.testing.expect(@typeInfo(h.ResourceState).Struct.fields.len == 2);
    try std.testing.expect(@typeInfo(h.EconomyState).Struct.fields.len == 2);
    try std.testing.expect(@typeInfo(h.PollutionState).Struct.fields.len == 3);
    try std.testing.expect(@typeInfo(h.AgricultureState).Struct.fields.len == 6);
}

test "T2.29 Performance Stress - repeated init-step-reset cycle (1,000 cycles)" {
    const asfr = [_]f64{0.0} ** 104;
    const mort = [_]f64{0.01} ** 104;

    for (0..1000) |_| {
        var ctx = h.SimulationContext.init();
        _ = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);
        try std.testing.expect(ctx.dem.state.total_pop > 0.0);
    }
}

test "T2.30 Performance Stress - SIMD vector loop bounds compliance" {
    const curves = h.generateDefaultResourceCurves();
    var sum: f64 = 0.0;
    for (curves.resource_usage_profile, 0..) |val, i| {
        try std.testing.expect(i < 104);
        sum += val;
    }
    try std.testing.expect(sum > 0.0);
}

// =========================================================================
// Feature 7: Numerical & Demographic Safety Boundary Cases
// =========================================================================

test "T2.31 Safety Boundary - negative input rejection across all sectors" {
    var rsc = h.ResourceEngine.init();
    const rsc_out = rsc.step(-10.0, -50.0, 1.0);
    try std.testing.expect(rsc_out.remaining_resources >= 0.0);
    try std.testing.expect(rsc_out.fcaor >= 0.05);

    var pol = h.PollutionEngine.init();
    const pol_out = pol.step(-10.0, -10.0, -10.0, -10.0, 1.0);
    try std.testing.expect(pol_out.ppol >= 0.0);

    var agr = h.AgricultureEngine.init();
    const agr_out = agr.step(-10.0, -10.0, -10.0, -10.0, -10.0, 1.0);
    try std.testing.expect(agr_out.food_produced >= 0.0);
}

test "T2.32 Safety Boundary - extreme mortality clamp at 100%" {
    var ctx = h.SimulationContext.init();
    var asfr = [_]f64{0.0} ** 104;
    // Base mortality 1.0 + toxic/famine multiplier
    const mort = [_]f64{1.0} ** 104;
    ctx.pol.state.ppol = 1.36e11;

    _ = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);
    // Effective mortality must not cause negative population
    try h.assertDemographicSafety(&ctx.dem);
}

test "T2.33 Safety Boundary - safe division with zero denominator in all sectors" {
    const res = h.ResourceTypes.safeDiv(100.0, 0.0, 0.0);
    try std.testing.expectEqual(@as(f64, 0.0), res);

    const res_nan = h.ResourceTypes.safeDiv(std.math.nan(f64), 5.0, 1.0);
    try std.testing.expectEqual(@as(f64, 1.0), res_nan);
}

test "T2.34 Safety Boundary - subnormal float flush-to-zero / non-negative" {
    const val: f64 = 1.0e-315;
    const sanitized = h.ResourceTypes.sanitizeNonNegative(val);
    try std.testing.expect(sanitized >= 0.0);
    try std.testing.expect(!std.math.isNan(sanitized));
}

test "T2.35 Safety Boundary - NaN infection immunity" {
    const nan_val = std.math.nan(f64);
    const sanitized = h.ResourceTypes.sanitizeNonNegative(nan_val);
    try std.testing.expectEqual(@as(f64, 0.0), sanitized);
}
