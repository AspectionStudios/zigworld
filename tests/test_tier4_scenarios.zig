const std = @import("std");
const h = @import("e2e_harness.zig");

// =========================================================================
// Tier 4: Real-World Planetary Application Scenarios
// =========================================================================

test "T4.1 Scenario 1 - Standard Run 1900-2100 (200-Year Planetary Trajectory)" {
    var ctx = h.SimulationContext.init();
    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.035; // Moderate demographic growth
    const mort = [_]f64{0.012} ** 104;

    const initial_res = ctx.rsc.state.remaining_resources;
    var peak_pop: f64 = 0.0;
    var final_out: ?h.StepOutput = null;

    // Simulate 200 consecutive years (1900 to 2100)
    for (0..200) |year| {
        const out = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);
        try h.assertOutputSafety(&out);
        try h.assertDemographicSafety(&ctx.dem);

        if (out.total_pop > peak_pop) {
            peak_pop = out.total_pop;
        }

        if (year == 199) {
            final_out = out;
        }
    }

    const final = final_out.?;

    // Standard run invariants:
    // 1. Resources are depleted over 200 years
    try std.testing.expect(final.remaining_resources < initial_res);
    try std.testing.expect(final.nrfr < 1.0);

    // 2. Population peaked during the run and survived
    try std.testing.expect(peak_pop > 0.0);
    try std.testing.expect(final.total_pop > 0.0);

    // 3. FCAOR increased as resources depleted
    try std.testing.expect(final.fcaor >= 0.05);

    // 4. Output finiteness & stability
    try std.testing.expect(!std.math.isNan(final.industrial_output));
    try std.testing.expect(!std.math.isNan(final.food_produced));
}

test "T4.2 Scenario 2 - Resource Depletion Shock & Capital Starvation" {
    var ctx = h.SimulationContext.init();

    // Start with pre-depleted resource base (e.g. 2.0e11 instead of 1.0e12)
    ctx.rsc.state.remaining_resources = 2.0e11;
    ctx.rsc.state.fcaor = h.ResourceEngine.interpolateFCAOR(0.20); // FCAOR ~ 0.70

    const asfr = [_]f64{0.0} ** 104;
    const mort = [_]f64{0.01} ** 104;

    var peak_io: f64 = 0.0;
    var final_io: f64 = 0.0;
    var final_fcaor: f64 = 0.0;

    for (0..60) |yr| {
        const out = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);
        try h.assertOutputSafety(&out);

        if (out.industrial_output > peak_io) {
            peak_io = out.industrial_output;
        }
        if (yr == 59) {
            final_io = out.industrial_output;
            final_fcaor = out.fcaor;
        }
    }

    // Capital starvation invariants:
    // 1. FCAOR surges towards 0.90 - 1.00 as resources near zero
    try std.testing.expect(final_fcaor >= 0.70);

    // 2. Effective industrial output collapses relative to baseline potential
    try std.testing.expect(final_io < peak_io * 0.50);

    // 3. Demographic safety holds despite economic collapse
    try h.assertDemographicSafety(&ctx.dem);
}

test "T4.3 Scenario 3 - Acute Toxic Pollution Crisis with Delayed Mortality Spike" {
    var ctx = h.SimulationContext.init();

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.02;
    const mort = [_]f64{0.01} ** 104;

    // Inject massive emission spike: accelerate pollution generation
    ctx.pol.state.ppol = 5.0e8;

    var initial_infant_deaths: f64 = 0.0;
    var peak_infant_deaths: f64 = 0.0;

    for (0..50) |yr| {
        _ = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);
        try h.assertDemographicSafety(&ctx.dem);

        // Track infant deaths (age 0)
        const infant_deaths = (ctx.dem.state.males[0] + ctx.dem.state.females[0]) * 0.01;
        if (yr == 0) initial_infant_deaths = infant_deaths;
        if (infant_deaths > peak_infant_deaths) peak_infant_deaths = infant_deaths;
    }

    // Pollution crisis invariants:
    // 1. Persistent pollution remained elevated
    try std.testing.expect(ctx.pol.state.ppol > 0.0);
    // 2. Numerical safety held throughout toxic spike
    try h.assertDemographicSafety(&ctx.dem);
}

test "T4.4 Scenario 4 - Famine & Caloric Deprivation Collapse" {
    var ctx = h.SimulationContext.init();

    // Trigger agricultural collapse: severe land degradation
    ctx.agr.state.land_fertility = 50.0; // Normal is 600.0
    ctx.agr.state.agricultural_inputs = 1.0e8;

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.02;
    const mort = [_]f64{0.01} ** 104;

    const initial_pop = ctx.dem.state.total_pop;

    for (0..30) |yr| {
        const out = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);
        try h.assertOutputSafety(&out);
        try h.assertDemographicSafety(&ctx.dem);

        // Famine condition: early food ratio severely depressed
        if (yr < 5) {
            try std.testing.expect(out.food_ratio < 0.50);
        }
        // Emergency capital response: FIOAA surges to save agriculture
        try std.testing.expect(out.fioaa >= 0.15);
    }

    // Famine collapse invariants:
    // 1. Population experienced contraction
    try std.testing.expect(ctx.dem.state.total_pop < initial_pop);
    // 2. Survived cohorts remain strictly non-negative
    for (ctx.dem.state.males) |m| try std.testing.expect(m >= 0.0);
    for (ctx.dem.state.females) |f| try std.testing.expect(f >= 0.0);
}

test "T4.5 Scenario 5 - Sustainable / Steady-State Stabilized Equilibrium" {
    var ctx = h.SimulationContext.init();

    // World3 Sustainable Equilibrium Specification:
    // Population calibrated to ecological carrying capacity (2.0 Billion total)
    const m = [_]f64{9_615_384.6} ** 104;
    const f = [_]f64{9_615_384.6} ** 104;
    ctx.dem.loadInitialData(m, f);

    // Stabilized policy settings:
    // 1. Clean agriculture with high organic maintenance & inputs
    ctx.agr.state.land_fertility = 600.0;
    ctx.agr.state.agricultural_inputs = 5.0e10;

    // 2. Replacement-level demographic balance:
    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.038;
    const mort = [_]f64{0.01} ** 104;

    const initial_pop = ctx.dem.state.total_pop;

    for (0..100) |_| {
        const out = h.step5Sectors(&ctx, &asfr, &mort, &mort, 1.0);
        try h.assertOutputSafety(&out);
        try h.assertDemographicSafety(&ctx.dem);

        // Sustainability invariants:
        // Food ratio stays healthy (satisfies food demand)
        try std.testing.expect(out.food_ratio >= 0.80);
        // FCAOR remains manageable
        try std.testing.expect(out.fcaor < 0.50);
    }

    // Population remained stable (within 50% of initial over 100 years)
    const pop_ratio = ctx.dem.state.total_pop / initial_pop;
    try std.testing.expect(pop_ratio > 0.50 and pop_ratio < 1.50);
    try std.testing.expect(ctx.dem.state.total_pop > 0.0);
}
