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

// ============================================================================
// ADVERSARIAL UNIFIED 5-SECTOR ENGINE TEST HARNESS
// ============================================================================

pub const StepSummary = struct {
    total_pop: f64,
    industrial_output: f64,
    services_output: f64,
    energy_twh: f64,
    remaining_resources: f64,
    nrfr: f64,
    fcaor: f64,
    ppol: f64,
    ppolx: f64,
    lmp: f64,
    food_produced: f64,
    food_ratio: f64,
    fioaa: f64,
    arable_land: f64,
    aiph: f64,
    births: f64,
    deaths: f64,
};

pub const Unified5SectorState = struct {
    dem: Demographics,
    econ: EconomyEngine,
    rsc: ResourceEngine,
    pol: PollutionEngine,
    agr: AgricultureEngine,

    econ_curves: economy.EconomyCurves,
    pol_curves: pollution.PollutionCurves,
    agr_curves: agriculture.AgricultureCurves,

    pub fn initStandard() Unified5SectorState {
        var dem = Demographics.init();
        var init_m = [_]f64{0.0} ** 104;
        var init_f = [_]f64{0.0} ** 104;
        for (0..104) |i| {
            init_m[i] = 38_461_538.46;
            init_f[i] = 38_461_538.46;
        }
        dem.loadInitialData(init_m, init_f);

        return .{
            .dem = dem,
            .econ = .{
                .state = .{
                    .industrial_capital = 105.0,
                    .service_capital = 128.0,
                },
            },
            .rsc = ResourceEngine.init(),
            .pol = PollutionEngine.init(),
            .agr = AgricultureEngine.init(),
            .econ_curves = economy.generateDefaultCurves(),
            .pol_curves = pollution.generateDefaultCurves(),
            .agr_curves = agriculture.generateDefaultCurves(),
        };
    }

    pub fn step(
        self: *@This(),
        asfr: *const [104]f64,
        base_mort_m: *const [104]f64,
        base_mort_f: *const [104]f64,
        dt: f64,
    ) StepSummary {
        // STEP 1: Demographic Aggregation
        const total_pop = self.dem.state.total_pop;
        var total_labor: f64 = 0.0;
        var total_food_demand: f64 = 0.0;
        var total_energy: f64 = 0.0;

        for (0..104) |age| {
            const cohort_pop = self.dem.state.males[age] + self.dem.state.females[age];
            total_labor += cohort_pop * self.econ_curves.labor_participation[age];
            total_food_demand += cohort_pop * self.agr_curves.food_demand_profile[age];
            total_energy += cohort_pop * self.econ_curves.energy_demand_profile[age];
        }

        // STEP 2: Economy Step (modulated by Resource Capital Drag FCAOR)
        const effective_ic = self.econ.state.industrial_capital * (1.0 - self.rsc.state.fcaor);
        const industrial_output = (@max(0.0, effective_ic) * 0.13184) * (total_labor / 1_000_000_000.0);
        const services_output = (self.econ.state.service_capital * 0.22111) * (total_labor / 1_000_000_000.0);
        const iopc = industrial_output / @max(1.0, total_pop);

        // STEP 3: Resources Step
        const rsc_out = self.rsc.step(total_pop, iopc, dt);

        // STEP 4: Agriculture Step
        const agr_out = self.agr.step(total_pop, industrial_output, iopc, self.pol.state.ppolx, total_food_demand, dt);

        // STEP 5: Pollution Step
        const pol_out = self.pol.step(total_pop, rsc_out.pcrum, agr_out.aiph, agr_out.arable_land, dt);

        // STEP 6: Collision-Zone Demographic Interface (Composite Mortality Composition)
        const food_mort = AgricultureEngine.calculateMortalityMultiplier(agr_out.food_ratio, &self.agr_curves.starvation_vulnerability);
        const poll_mort = PollutionEngine.calculateMortalityMultiplier(pol_out.ppolx, &self.pol_curves.vulnerability_profile);

        var eff_mort_m: [104]f64 = undefined;
        var eff_mort_f: [104]f64 = undefined;

        for (0..104) |age| {
            const combined_mult = food_mort[age] * poll_mort[age];
            eff_mort_m[age] = @min(1.0, @max(0.0, base_mort_m[age] * combined_mult));
            eff_mort_f[age] = @min(1.0, @max(0.0, base_mort_f[age] * combined_mult));
        }

        // STEP 7: Demographics Step
        self.dem.step(asfr.*, eff_mort_m, eff_mort_f);

        return .{
            .total_pop = self.dem.state.total_pop,
            .industrial_output = industrial_output,
            .services_output = services_output,
            .energy_twh = total_energy,
            .remaining_resources = rsc_out.remaining_resources,
            .nrfr = rsc_out.nrfr,
            .fcaor = rsc_out.fcaor,
            .ppol = pol_out.ppol,
            .ppolx = pol_out.ppolx,
            .lmp = pol_out.lmp,
            .food_produced = agr_out.food_produced,
            .food_ratio = agr_out.food_ratio,
            .fioaa = agr_out.fioaa,
            .arable_land = agr_out.arable_land,
            .aiph = agr_out.aiph,
            .births = self.dem.state.births,
            .deaths = self.dem.state.deaths,
        };
    }
};

pub fn assertStepSummarySafety(s: *const StepSummary) !void {
    try std.testing.expect(!std.math.isNan(s.total_pop));
    try std.testing.expect(!std.math.isInf(s.total_pop));
    try std.testing.expect(s.total_pop >= 0.0);

    try std.testing.expect(!std.math.isNan(s.industrial_output));
    try std.testing.expect(!std.math.isInf(s.industrial_output));

    try std.testing.expect(!std.math.isNan(s.services_output));
    try std.testing.expect(!std.math.isInf(s.services_output));

    try std.testing.expect(!std.math.isNan(s.energy_twh));
    try std.testing.expect(!std.math.isInf(s.energy_twh));

    try std.testing.expect(!std.math.isNan(s.remaining_resources));
    try std.testing.expect(!std.math.isInf(s.remaining_resources));
    try std.testing.expect(s.remaining_resources >= 0.0);

    try std.testing.expect(!std.math.isNan(s.nrfr));
    try std.testing.expect(!std.math.isInf(s.nrfr));
    try std.testing.expect(s.nrfr >= 0.0 and s.nrfr <= 1.0);

    try std.testing.expect(!std.math.isNan(s.fcaor));
    try std.testing.expect(!std.math.isInf(s.fcaor));
    try std.testing.expect(s.fcaor >= 0.05 and s.fcaor <= 1.00);

    try std.testing.expect(!std.math.isNan(s.ppol));
    try std.testing.expect(!std.math.isInf(s.ppol));
    try std.testing.expect(s.ppol >= 0.0);

    try std.testing.expect(!std.math.isNan(s.ppolx));
    try std.testing.expect(!std.math.isInf(s.ppolx));
    try std.testing.expect(s.ppolx >= 0.0);

    try std.testing.expect(!std.math.isNan(s.lmp));
    try std.testing.expect(!std.math.isInf(s.lmp));
    try std.testing.expect(s.lmp >= 0.05 and s.lmp <= 1.00);

    try std.testing.expect(!std.math.isNan(s.food_produced));
    try std.testing.expect(!std.math.isInf(s.food_produced));
    try std.testing.expect(s.food_produced >= 0.0);

    try std.testing.expect(!std.math.isNan(s.food_ratio));
    try std.testing.expect(!std.math.isInf(s.food_ratio));
    try std.testing.expect(s.food_ratio >= 0.0);

    try std.testing.expect(!std.math.isNan(s.fioaa));
    try std.testing.expect(!std.math.isInf(s.fioaa));
    try std.testing.expect(s.fioaa >= 0.0 and s.fioaa <= 0.40);

    try std.testing.expect(!std.math.isNan(s.births));
    try std.testing.expect(!std.math.isInf(s.births));
    try std.testing.expect(s.births >= 0.0);

    try std.testing.expect(!std.math.isNan(s.deaths));
    try std.testing.expect(!std.math.isInf(s.deaths));
    try std.testing.expect(s.deaths >= 0.0);
}

pub fn assertDemographicCohortsSafety(dem: *const Demographics) !void {
    try std.testing.expect(!std.math.isNan(dem.state.total_pop));
    try std.testing.expect(!std.math.isInf(dem.state.total_pop));
    try std.testing.expect(dem.state.total_pop >= 0.0);

    for (0..104) |i| {
        const m = dem.state.males[i];
        const f = dem.state.females[i];
        try std.testing.expect(!std.math.isNan(m));
        try std.testing.expect(!std.math.isInf(m));
        try std.testing.expect(m >= 0.0);

        try std.testing.expect(!std.math.isNan(f));
        try std.testing.expect(!std.math.isInf(f));
        try std.testing.expect(f >= 0.0);
    }
}

// ============================================================================
// SUITE 1: 100x ACUTE TOXIC POLLUTION SHOCK
// ============================================================================

test "Tier 5 Adversarial: 100x Acute Persistent Pollution Shock (PPOL = 2.5e9, 100 Years)" {
    var sim = Unified5SectorState.initStandard();

    // Inject 100x persistent pollution shock (2.5e9 vs baseline 2.5e7)
    sim.pol.state.ppol = 2.5e9;
    sim.pol.state.ppolx = 2.5e9 / PollutionEngine.PPOL70; // ~18.38
    sim.pol.state.delay_stages = [3]f64{ 1.2e9, 1.2e9, 1.2e9 };

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.035;
    const base_mort = [_]f64{0.012} ** 104;

    for (0..100) |_| {
        const out = sim.step(&asfr, &base_mort, &base_mort, 1.0);
        try assertStepSummarySafety(&out);
        try assertDemographicCohortsSafety(&sim.dem);

        // Pollution stock and index must remain elevated and valid
        try std.testing.expect(out.ppol > 0.0);
        try std.testing.expect(out.ppolx > 0.0);
        try std.testing.expect(out.lmp <= 1.00 and out.lmp >= 0.05);
    }

    // Population must have contracted or evolved safely without numerical corruption
    try std.testing.expect(sim.dem.state.total_pop >= 0.0);
}

test "Tier 5 Adversarial: 1000x Extreme Toxic Catastrophe (PPOL = 1.36e11, PPOLX = 1000.0)" {
    var sim = Unified5SectorState.initStandard();

    // Inject catastrophic 1000x benchmark pollution
    sim.pol.state.ppol = 1.36e11;
    sim.pol.state.ppolx = 1000.0;
    sim.pol.state.delay_stages = [3]f64{ 1.0e11, 1.0e11, 1.0e11 };

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.02;
    const base_mort = [_]f64{0.015} ** 104;

    for (0..100) |_| {
        const out = sim.step(&asfr, &base_mort, &base_mort, 1.0);
        try assertStepSummarySafety(&out);
        try assertDemographicCohortsSafety(&sim.dem);

        // Under extreme toxicity, LMP must clamp at or above floor 0.05
        try std.testing.expect(out.lmp >= 0.05);
        try std.testing.expect(out.lmp <= 0.20);
    }
}

test "Tier 5 Adversarial: Acute Mid-Simulation Pollution Burst & Delay3 Ringing" {
    var sim = Unified5SectorState.initStandard();

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.03;
    const base_mort = [_]f64{0.01} ** 104;

    // Run 20 years baseline
    for (0..20) |_| {
        const out = sim.step(&asfr, &base_mort, &base_mort, 1.0);
        try assertStepSummarySafety(&out);
    }

    // Year 21: Acute emission surge (100x industrial activity)
    sim.pol.state.delay_stages[0] += 5.0e9;

    for (0..40) |_| {
        const out = sim.step(&asfr, &base_mort, &base_mort, 1.0);
        try assertStepSummarySafety(&out);
        try assertDemographicCohortsSafety(&sim.dem);
    }
}

// ============================================================================
// SUITE 2: TOTAL CROP FAILURE & SEVERE FAMINE SHOCK
// ============================================================================

test "Tier 5 Adversarial: Total Crop Failure (0.0 Arable Land, 100 Years)" {
    var sim = Unified5SectorState.initStandard();

    // Destroy all arable land on Earth
    sim.agr.state.arable_land = 0.0;
    sim.agr.state.agricultural_inputs = 0.0;

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.035;
    const base_mort = [_]f64{0.012} ** 104;

    for (0..100) |_| {
        const out = sim.step(&asfr, &base_mort, &base_mort, 1.0);
        try assertStepSummarySafety(&out);
        try assertDemographicCohortsSafety(&sim.dem);

        // Zero arable land yields zero food
        try std.testing.expectEqual(@as(f64, 0.0), out.food_produced);
        try std.testing.expectEqual(@as(f64, 0.0), out.arable_land);
    }

    // Population should collapse to 0.0 due to 100% mortality under total famine
    try std.testing.expectEqual(@as(f64, 0.0), sim.dem.state.total_pop);
    try std.testing.expectEqual(@as(f64, 0.0), sim.dem.state.births);
    try std.testing.expectEqual(@as(f64, 0.0), sim.dem.state.deaths);
}

test "Tier 5 Adversarial: Severe Chronic Famine (90% Caloric Deficit, Food Ratio = 0.10)" {
    var sim = Unified5SectorState.initStandard();

    // Deplete arable land and inputs by 90%
    sim.agr.state.arable_land = 0.09e9;
    sim.agr.state.agricultural_inputs = 5.0e8;

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.02;
    const base_mort = [_]f64{0.01} ** 104;

    for (0..60) |_| {
        const out = sim.step(&asfr, &base_mort, &base_mort, 1.0);
        try assertStepSummarySafety(&out);
        try assertDemographicCohortsSafety(&sim.dem);

        // Under acute famine, FIOAA capital allocation must divert maximum resources
        try std.testing.expect(out.fioaa >= 0.20);
    }

    // Demographics remain finite and non-negative
    try std.testing.expect(sim.dem.state.total_pop >= 0.0);
}

test "Tier 5 Adversarial: Soil Exhaustion to Minimum Fertility & Regeneration" {
    var sim = Unified5SectorState.initStandard();

    // Pre-corrupt land fertility to 0.0
    sim.agr.state.land_fertility = 0.0;

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.03;
    const base_mort = [_]f64{0.01} ** 104;

    for (0..30) |_| {
        const out = sim.step(&asfr, &base_mort, &base_mort, 1.0);
        try assertStepSummarySafety(&out);
        try assertDemographicCohortsSafety(&sim.dem);

        // Land fertility must be clamped at or above physical minimum (10.0)
        try std.testing.expect(sim.agr.state.land_fertility >= AgricultureEngine.MIN_LAND_FERTILITY);
    }
}

// ============================================================================
// SUITE 3: COMPLETE RESOURCE EXHAUSTION (0.0 NR)
// ============================================================================

test "Tier 5 Adversarial: Instant Complete Resource Exhaustion (0.0 NR, 10,000 Steps)" {
    var sim = Unified5SectorState.initStandard();

    // Exhaust all non-renewable resources immediately
    sim.rsc.state.remaining_resources = 0.0;
    sim.rsc.state.fcaor = 1.00;

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.03;
    const base_mort = [_]f64{0.01} ** 104;

    for (0..10_000) |_| {
        const out = sim.step(&asfr, &base_mort, &base_mort, 1.0);
        try assertStepSummarySafety(&out);
        try assertDemographicCohortsSafety(&sim.dem);

        // Complete exhaustion invariants
        try std.testing.expectEqual(@as(f64, 0.0), out.remaining_resources);
        try std.testing.expectEqual(@as(f64, 0.0), out.nrfr);
        try std.testing.expectEqual(@as(f64, 1.00), out.fcaor);
        // Industrial capital completely diverted to extraction drag: industrial output = 0.0
        try std.testing.expectEqual(@as(f64, 0.0), out.industrial_output);
    }
}

test "Tier 5 Adversarial: Subnormal Resource Depletion Boundary (1e-320 -> 0.0)" {
    var sim = Unified5SectorState.initStandard();

    sim.rsc.state.remaining_resources = 1.0e-320;
    sim.rsc.state.fcaor = 0.99;

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.03;
    const base_mort = [_]f64{0.01} ** 104;

    for (0..50) |_| {
        const out = sim.step(&asfr, &base_mort, &base_mort, 1.0);
        try assertStepSummarySafety(&out);
        try assertDemographicCohortsSafety(&sim.dem);

        try std.testing.expect(out.remaining_resources >= 0.0);
    }
    try std.testing.expectEqual(@as(f64, 0.0), sim.rsc.state.remaining_resources);
}

// ============================================================================
// SUITE 4: ZERO POPULATION EXTINCTION & DEMOGRAPHIC EDGE CASES
// ============================================================================

test "Tier 5 Adversarial: Planetary Void (Zero Initial Population, 200 Years)" {
    var sim = Unified5SectorState.initStandard();

    // Zero out all population cohorts
    @memset(&sim.dem.state.males, 0.0);
    @memset(&sim.dem.state.females, 0.0);
    sim.dem.state.total_pop = 0.0;
    sim.dem.state.births = 0.0;
    sim.dem.state.deaths = 0.0;

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.05;
    const base_mort = [_]f64{0.01} ** 104;

    for (0..200) |_| {
        const out = sim.step(&asfr, &base_mort, &base_mort, 1.0);
        try assertStepSummarySafety(&out);
        try assertDemographicCohortsSafety(&sim.dem);

        try std.testing.expectEqual(@as(f64, 0.0), out.total_pop);
        try std.testing.expectEqual(@as(f64, 0.0), out.industrial_output);
        try std.testing.expectEqual(@as(f64, 0.0), out.services_output);
        try std.testing.expectEqual(@as(f64, 0.0), out.energy_twh);
        try std.testing.expectEqual(@as(f64, 0.0), out.births);
        try std.testing.expectEqual(@as(f64, 0.0), out.deaths);
    }
}

test "Tier 5 Adversarial: Sudden Extinction & Post-Extinction Planetary Evolution" {
    var sim = Unified5SectorState.initStandard();

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.03;
    const normal_mort = [_]f64{0.01} ** 104;
    const lethal_mort = [_]f64{1.0} ** 104; // 100% mortality

    // 10 years normal
    for (0..10) |_| {
        const out = sim.step(&asfr, &normal_mort, &normal_mort, 1.0);
        try assertStepSummarySafety(&out);
    }

    // Year 11: Lethal event
    {
        const out = sim.step(&asfr, &lethal_mort, &lethal_mort, 1.0);
        try assertStepSummarySafety(&out);
    }

    // Verify extinction
    try std.testing.expectEqual(@as(f64, 0.0), sim.dem.state.total_pop);

    // 50 more years in extinct state
    for (0..50) |_| {
        const out = sim.step(&asfr, &normal_mort, &normal_mort, 1.0);
        try assertStepSummarySafety(&out);
        try assertDemographicCohortsSafety(&sim.dem);
        try std.testing.expectEqual(@as(f64, 0.0), out.total_pop);
    }
}

test "Tier 5 Adversarial: Two-Person (Adam & Eve) Recolonization" {
    var sim = Unified5SectorState.initStandard();

    // Exactly 1 male and 1 female at reproductive age 20
    @memset(&sim.dem.state.males, 0.0);
    @memset(&sim.dem.state.females, 0.0);
    sim.dem.state.males[20] = 1.0;
    sim.dem.state.females[20] = 1.0;
    sim.dem.state.total_pop = 2.0;

    var asfr = [_]f64{0.0} ** 104;
    asfr[20] = 0.50; // 50% birth rate
    const base_mort = [_]f64{0.005} ** 104;

    for (0..30) |_| {
        const out = sim.step(&asfr, &base_mort, &base_mort, 1.0);
        try assertStepSummarySafety(&out);
        try assertDemographicCohortsSafety(&sim.dem);
        try std.testing.expect(out.total_pop > 0.0);
    }
}

test "Tier 5 Adversarial: All-Male Demographic Imbalance (Extinction)" {
    var sim = Unified5SectorState.initStandard();

    // All female cohorts zeroed out
    @memset(&sim.dem.state.females, 0.0);
    sim.dem.state.total_pop = 4.0e9;

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.05;
    var base_mort = [_]f64{0.02} ** 104;
    base_mort[103] = 1.00; // Terminal age cohort mortality is 100%

    var prev_pop = sim.dem.state.total_pop;
    for (0..150) |_| {
        const out = sim.step(&asfr, &base_mort, &base_mort, 1.0);
        try assertStepSummarySafety(&out);
        try assertDemographicCohortsSafety(&sim.dem);
        // With zero females, births must be zero every year
        try std.testing.expectEqual(@as(f64, 0.0), out.births);
        // Population must monotonically decrease
        try std.testing.expect(out.total_pop <= prev_pop);
        prev_pop = out.total_pop;
    }

    // After 150 years without births and terminal mortality at 103, all cohorts have aged out to exactly 0.0
    try std.testing.expectEqual(@as(f64, 0.0), sim.dem.state.total_pop);
}

test "Tier 5 Adversarial: All-Female Demographic Imbalance (Male Cohort Spontaneous Generation)" {
    var sim = Unified5SectorState.initStandard();

    // All male cohorts zeroed out
    @memset(&sim.dem.state.males, 0.0);
    sim.dem.state.total_pop = 4.0e9;

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.05;
    const base_mort = [_]f64{0.01} ** 104;

    // Step 1 year: births occur
    const out = sim.step(&asfr, &base_mort, &base_mort, 1.0);
    try assertStepSummarySafety(&out);
    try assertDemographicCohortsSafety(&sim.dem);

    // Male infants must have been generated via the biological 1.05/2.05 sex ratio!
    try std.testing.expect(sim.dem.state.males[0] > 0.0);
    try std.testing.expect(out.births > 0.0);
}

// ============================================================================
// SUITE 5: SUBNORMAL FLOATING POINT INJECTIONS
// ============================================================================

test "Tier 5 Adversarial: Subnormal Float Injections into Population Cohorts" {
    var sim = Unified5SectorState.initStandard();

    const subnormal_1 = std.math.floatTrueMin(f64); // ~5e-324
    const subnormal_2: f64 = 1.0e-310;
    const subnormal_3: f64 = 2.2250738585072014e-308; // Normal min

    for (0..104) |i| {
        sim.dem.state.males[i] = if (i % 2 == 0) subnormal_1 else subnormal_2;
        sim.dem.state.females[i] = subnormal_3;
    }
    sim.dem.state.total_pop = 104.0 * (subnormal_1 + subnormal_3);

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.03;
    const base_mort = [_]f64{0.01} ** 104;

    for (0..50) |_| {
        const out = sim.step(&asfr, &base_mort, &base_mort, 1.0);
        try assertStepSummarySafety(&out);
        try assertDemographicCohortsSafety(&sim.dem);
    }
}

test "Tier 5 Adversarial: Subnormal Float Injections into Physical Sector Stocks" {
    var sim = Unified5SectorState.initStandard();

    const sub = std.math.floatTrueMin(f64);
    sim.rsc.state.remaining_resources = sub;
    sim.pol.state.ppol = sub;
    sim.agr.state.arable_land = sub;
    sim.agr.state.land_fertility = sub;
    sim.agr.state.agricultural_inputs = sub;

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.03;
    const base_mort = [_]f64{0.01} ** 104;

    for (0..30) |_| {
        const out = sim.step(&asfr, &base_mort, &base_mort, 1.0);
        try assertStepSummarySafety(&out);
        try assertDemographicCohortsSafety(&sim.dem);
    }
}

test "Tier 5 Adversarial: Infinitesimal Time Step dt (1e-300)" {
    var sim = Unified5SectorState.initStandard();

    var asfr = [_]f64{0.0} ** 104;
    for (15..50) |i| asfr[i] = 0.03;
    const base_mort = [_]f64{0.01} ** 104;

    for (0..20) |_| {
        const out = sim.step(&asfr, &base_mort, &base_mort, 1.0e-300);
        try assertStepSummarySafety(&out);
        try assertDemographicCohortsSafety(&sim.dem);
    }
}

// ============================================================================
// SUITE 6: PRE-CORRUPTED IEEE-754 SPECIAL VALUES
// ============================================================================

test "Tier 5 Adversarial: Pre-Corrupted NaN / Inf in Sector States" {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);

    // Test matrix of corruptions
    const corruptions = [_]f64{ nan, inf, -inf, -0.0, -1.0e9 };

    for (corruptions) |c| {
        var sim = Unified5SectorState.initStandard();
        sim.rsc.state.remaining_resources = c;
        sim.pol.state.ppol = c;
        sim.agr.state.agricultural_inputs = c;

        var asfr = [_]f64{0.0} ** 104;
        for (15..50) |i| asfr[i] = 0.03;
        const base_mort = [_]f64{0.01} ** 104;

        const out = sim.step(&asfr, &base_mort, &base_mort, 1.0);

        // Core invariants: NO NaN anywhere in the outputs
        try std.testing.expect(!std.math.isNan(out.total_pop));
        try std.testing.expect(!std.math.isNan(out.industrial_output));
        try std.testing.expect(!std.math.isNan(out.services_output));
        try std.testing.expect(!std.math.isNan(out.energy_twh));
        try std.testing.expect(!std.math.isNan(out.remaining_resources));
        try std.testing.expect(!std.math.isNan(out.nrfr));
        try std.testing.expect(!std.math.isNan(out.fcaor));
        try std.testing.expect(!std.math.isNan(out.ppol));
        try std.testing.expect(!std.math.isNan(out.ppolx));
        try std.testing.expect(!std.math.isNan(out.lmp));
        try std.testing.expect(!std.math.isNan(out.food_produced));
        try std.testing.expect(!std.math.isNan(out.food_ratio));
        try std.testing.expect(!std.math.isNan(out.fioaa));
        try std.testing.expect(!std.math.isNan(out.births));
        try std.testing.expect(!std.math.isNan(out.deaths));

        // Derived macroeconomic & demographic variables MUST be strictly finite
        try std.testing.expect(!std.math.isInf(out.total_pop));
        try std.testing.expect(!std.math.isInf(out.industrial_output));
        try std.testing.expect(!std.math.isInf(out.services_output));
        try std.testing.expect(!std.math.isInf(out.energy_twh));
        try std.testing.expect(!std.math.isInf(out.nrfr));
        try std.testing.expect(!std.math.isInf(out.fcaor));
        try std.testing.expect(!std.math.isInf(out.lmp));
        try std.testing.expect(!std.math.isInf(out.food_produced));
        try std.testing.expect(!std.math.isInf(out.food_ratio));
        try std.testing.expect(!std.math.isInf(out.fioaa));

        // Non-negativity bounds
        try std.testing.expect(out.total_pop >= 0.0);
        try std.testing.expect(out.remaining_resources >= 0.0);
        try std.testing.expect(out.nrfr >= 0.0 and out.nrfr <= 1.0);
        try std.testing.expect(out.fcaor >= 0.05 and out.fcaor <= 1.00);
        try std.testing.expect(out.lmp >= 0.05 and out.lmp <= 1.00);
        try std.testing.expect(out.food_produced >= 0.0);
        try std.testing.expect(out.food_ratio >= 0.0);
        try std.testing.expect(out.fioaa >= 0.0 and out.fioaa <= 0.40);

        try assertDemographicCohortsSafety(&sim.dem);
    }
}

// ============================================================================
// SUITE 7: MONTE CARLO CHAOTIC MULTI-STRESS FUZZING
// ============================================================================

test "Tier 5 Adversarial: 10,000 Chaotic Pseudo-Random Monte Carlo 5-Sector Steps" {
    var prng = std.Random.DefaultPrng.init(0xFEED_FACE_CAFE_BEEF);
    const rand = prng.random();

    var sim = Unified5SectorState.initStandard();

    var asfr = [_]f64{0.0} ** 104;
    var base_mort_m = [_]f64{0.01} ** 104;
    var base_mort_f = [_]f64{0.01} ** 104;

    for (0..10_000) |_| {
        // Randomly mutate environmental conditions
        const shock_mode = rand.intRangeAtMost(u8, 0, 8);
        switch (shock_mode) {
            0 => {
                // Pollution shock
                sim.pol.state.ppol = rand.float(f64) * 1.0e11;
            },
            1 => {
                // Food shock (famine)
                sim.agr.state.arable_land = rand.float(f64) * 1.0e9;
                sim.agr.state.land_fertility = rand.float(f64) * 600.0;
            },
            2 => {
                // Resource shock
                sim.rsc.state.remaining_resources = rand.float(f64) * 1.0e12;
            },
            3 => {
                // Fertility perturbation
                const r_asfr = rand.float(f64) * 0.10;
                for (15..50) |age| asfr[age] = r_asfr;
            },
            4 => {
                // Mortality shock
                const r_mort = rand.float(f64) * 0.05;
                for (0..104) |age| {
                    base_mort_m[age] = r_mort;
                    base_mort_f[age] = r_mort;
                }
            },
            5 => {
                // Subnormal or zero pop injection
                if (rand.boolean()) {
                    sim.dem.state.total_pop = 0.0;
                    @memset(&sim.dem.state.males, 0.0);
                    @memset(&sim.dem.state.females, 0.0);
                }
            },
            else => {},
        }

        const dt = if (rand.boolean()) 1.0 else rand.float(f64) * 2.0;

        const out = sim.step(&asfr, &base_mort_m, &base_mort_f, dt);
        try assertStepSummarySafety(&out);
        try assertDemographicCohortsSafety(&sim.dem);
    }
}
