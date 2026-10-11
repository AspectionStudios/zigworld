const std = @import("std");
const h = @import("e2e_harness.zig");

// =========================================================================
// Tier 3: Pairwise Cross-Feature Interactions
// =========================================================================

test "T3.1 Interaction - Resources x Economy (FCAOR throttling IO)" {
    var ctx_high = h.SimulationContext.init();
    var ctx_depleted = h.SimulationContext.init();

    // High resources: NRFR = 1.0, FCAOR = 0.05
    ctx_high.rsc.state.remaining_resources = 1.0e12;
    ctx_high.rsc.state.fcaor = 0.05;

    // Depleted resources: NRFR = 0.1, FCAOR = 0.90
    ctx_depleted.rsc.state.remaining_resources = 1.0e11;
    ctx_depleted.rsc.state.fcaor = 0.90;

    const asfr = [_]f64{0.0} ** 104;
    const mort = [_]f64{0.01} ** 104;

    const out_high = h.step5Sectors(&ctx_high, &asfr, &mort, &mort, 1.0);
    const out_depleted = h.step5Sectors(&ctx_depleted, &asfr, &mort, &mort, 1.0);

    // IO with FCAOR=0.90 must be ~ (1 - 0.90) / (1 - 0.05) ≈ 0.105x of high IO
    const ratio = out_depleted.industrial_output / out_high.industrial_output;
    try std.testing.expect(ratio < 0.15);
    try std.testing.expect(ratio > 0.05);
}

test "T3.2 Interaction - Economy x Resources (IOPC driving NRUR)" {
    var rsc_low = h.ResourceEngine.init();
    var rsc_high = h.ResourceEngine.init();

    const pop = 8.0e9;
    const iopc_low = 100.0; // Low development: PCRUM ~ 0.42
    const iopc_high = 1200.0; // High development: PCRUM ~ 6.80

    const out_low = rsc_low.step(pop, iopc_low, 1.0);
    const out_high = rsc_high.step(pop, iopc_high, 1.0);

    try std.testing.expect(out_high.resource_usage_rate > 10.0 * out_low.resource_usage_rate);
    try std.testing.expect(out_high.remaining_resources < out_low.remaining_resources);
}

test "T3.3 Interaction - Agriculture x Demographics (FR driving famine mortality)" {
    var ctx_surplus = h.SimulationContext.init();
    var ctx_famine = h.SimulationContext.init();

    // Normal fertility
    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.04;
    const mort = [_]f64{0.01} ** 104;

    // Famine: destroy land fertility and inputs
    ctx_famine.agr.state.land_fertility = 50.0;
    ctx_famine.agr.state.agricultural_inputs = 1.0e8;

    // High inputs for surplus
    ctx_surplus.agr.state.agricultural_inputs = 2.0e11;

    const out_surplus = h.step5Sectors(&ctx_surplus, &asfr, &mort, &mort, 1.0);
    const out_famine = h.step5Sectors(&ctx_famine, &asfr, &mort, &mort, 1.0);

    try std.testing.expect(out_surplus.food_ratio > out_famine.food_ratio);
    try std.testing.expect(out_famine.food_ratio < 0.1);
    // Population in famine must decline or grow significantly slower
    try std.testing.expect(out_famine.total_pop < out_surplus.total_pop);
}

test "T3.4 Interaction - Pollution x Demographics (Toxic emissions driving infant/elderly mortality)" {
    var ctx_clean = h.SimulationContext.init();
    var ctx_toxic = h.SimulationContext.init();

    ctx_toxic.pol.state.ppol = 1.36e10; // PPOLX = 100.0
    const asfr = [_]f64{0.0} ** 104;
    const mort = [_]f64{0.01} ** 104;

    const out_clean = h.step5Sectors(&ctx_clean, &asfr, &mort, &mort, 1.0);
    const out_toxic = h.step5Sectors(&ctx_toxic, &asfr, &mort, &mort, 1.0);

    try std.testing.expect(out_toxic.total_pop < out_clean.total_pop);
    // Deaths in toxic world must be higher
    try std.testing.expect(ctx_toxic.dem.state.deaths > ctx_clean.dem.state.deaths);
}

test "T3.5 Interaction - Pollution x Agriculture (Pollution degradation of soil fertility LFDR)" {
    var agr_clean = h.AgricultureEngine.init();
    var agr_polluted = h.AgricultureEngine.init();

    const pop = 8.0e9;
    const food_demand = 8.0e9 * 230.0;

    for (0..20) |_| {
        _ = agr_clean.step(pop, 30.0e12, 3750.0, 0.2, food_demand, 1.0);
        _ = agr_polluted.step(pop, 30.0e12, 3750.0, 50.0, food_demand, 1.0); // Heavy pollution
    }

    try std.testing.expect(agr_clean.state.land_fertility > agr_polluted.state.land_fertility);
}

test "T3.6 Interaction - Economy x Agriculture (FIOAA capital diversion under food shortage)" {
    var agr = h.AgricultureEngine.init();
    agr.state.perceived_food_ratio = 0.4; // Famine perception

    const out = agr.step(8.0e9, 30.0e12, 3750.0, 1.0, 8.0e9 * 230.0, 1.0);
    // Industrial capital diverted to agriculture must surge
    try std.testing.expect(out.fioaa >= 0.30);
}

test "T3.7 Interaction - Agriculture x Pollution (Agricultural chemicals contributing to persistent pollution)" {
    var pol_organic = h.PollutionEngine.init();
    var pol_chemical = h.PollutionEngine.init();

    // Step with identical population and PCRUM, but different AIPH
    const out_org = pol_organic.step(8.0e9, 2.0, 5.0, 0.9e9, 1.0);
    const out_chem = pol_chemical.step(8.0e9, 2.0, 500.0, 0.9e9, 1.0);

    try std.testing.expect(out_chem.ppol > out_org.ppol);
}

test "T3.8 Interaction - Demographics x Economy (Labor force participation driving IO and SO)" {
    var dem_young = h.Demographics.init();
    var dem_working = h.Demographics.init();

    var m_young = [_]f64{0.0} ** 104;
    var f_young = [_]f64{0.0} ** 104;
    var m_working = [_]f64{0.0} ** 104;
    var f_working = [_]f64{0.0} ** 104;

    // Young population (age 5): 0 labor participation
    m_young[5] = 4.0e9;
    f_young[5] = 4.0e9;

    // Prime working population (age 45): peak labor participation
    m_working[45] = 4.0e9;
    f_working[45] = 4.0e9;

    dem_young.loadInitialData(m_young, f_young);
    dem_working.loadInitialData(m_working, f_working);

    var econ = h.EconomyEngine{
        .state = .{ .industrial_capital = 100.0, .service_capital = 100.0 },
    };
    const curves = h.generateDefaultEconomyCurves();

    const out_young = econ.step(&dem_young.state.males, &dem_young.state.females, &curves);
    const out_working = econ.step(&dem_working.state.males, &dem_working.state.females, &curves);

    try std.testing.expectEqual(@as(f64, 0.0), out_young.industrial_output);
    try std.testing.expect(out_working.industrial_output > 10.0);
}

test "T3.9 Interaction - 3-Way Collision: Resources x Economy x Pollution" {
    var ctx = h.SimulationContext.init();
    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.03;
    const mort = [_]f64{0.01} ** 104;

    // Simulate 30 years of industrial growth
    for (0..30) |_| {
        const out = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);
        try h.assertOutputSafety(&out);
    }

    // Resources must be depleted, pollution must be finite and positive
    try std.testing.expect(ctx.rsc.state.remaining_resources < 1.0e12);
    try std.testing.expect(ctx.pol.state.ppol > 0.0);
    try std.testing.expect(!std.math.isNan(ctx.pol.state.ppol));
    try h.assertDemographicSafety(&ctx.dem);
}
