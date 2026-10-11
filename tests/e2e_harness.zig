const std = @import("std");

// Always import the verified Demographic and Economy engines
pub const population = @import("src/population_padded.zig");
pub const economy = @import("src/economy.zig");

pub const Demographics = population.Demographics;
pub const PopulationState = population.PopulationState;
pub const EconomyEngine = economy.EconomyEngine;
pub const EconomyState = economy.EconomyState;
pub const EconomyCurves = economy.EconomyCurves;
pub const generateDefaultEconomyCurves = economy.generateDefaultCurves;

// =========================================================================
// Verified M1 Resources Sector Engine
// =========================================================================

pub const ResourceTypes = @import("src/resources.zig");
pub const ResourceState = ResourceTypes.ResourceState;
pub const ResourceCurves = ResourceTypes.ResourceCurves;
pub const ResourceOutput = ResourceTypes.ResourceOutput;
pub const ResourceEngine = ResourceTypes.ResourceEngine;

// =========================================================================
// Pollution Sector Specification Engine (M2 Contract Oracle)
// =========================================================================

pub const PollutionState = struct {
    ppol: f64, // Persistent pollution units (Initial: 2.5e7)
    ppolx: f64, // Index normalized to 1970 (1.36e8)
    delay_stages: [3]f64, // 3rd-order delay transmission state
};

pub const PollutionCurves = struct {
    vulnerability_profile: [104]f64 align(64),
};

pub const PollutionOutput = struct {
    ppol: f64,
    ppolx: f64,
    lmp: f64, // Lifetime multiplier from pollution [0.2, 1.0]
};

pub const PollutionEngine = struct {
    state: PollutionState,

    pub fn init() @This() {
        const initial_ppol = 2.5e7;
        const initial_ppolx = initial_ppol / 1.36e8;
        const initial_ppgr = 1.2e7;
        return .{
            .state = .{
                .ppol = initial_ppol,
                .ppolx = initial_ppolx,
                .delay_stages = [3]f64{ initial_ppgr, initial_ppgr, initial_ppgr },
            },
        };
    }

    pub fn interpolateLMP(ppolx: f64) f64 {
        const knots = [11]f64{ 0.0, 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0 };
        const vals = [11]f64{ 1.0, 0.99, 0.97, 0.95, 0.90, 0.85, 0.75, 0.65, 0.55, 0.40, 0.20 };
        const clamped = @min(@max(ppolx, 0.0), 100.0);
        const u = clamped / 10.0;
        const idx = @min(@as(usize, @intFromFloat(u)), 9);
        const t = (clamped - knots[idx]) / (knots[idx + 1] - knots[idx]);
        const base_lmp = vals[idx] + t * (vals[idx + 1] - vals[idx]);
        if (ppolx > 100.0) {
            const excess = ppolx - 100.0;
            return @max(0.05, 0.20 - excess * 0.001);
        }
        return base_lmp;
    }

    pub fn step(self: *@This(), total_pop: f64, pcrum: f64, aiph: f64, arable_land: f64, dt: f64) PollutionOutput {
        const effective_pop = @max(0.0, total_pop);
        const ppgio = 0.02 * (effective_pop * pcrum);
        const ppgao = 0.001 * (@max(0.0, aiph) * @max(0.0, arable_land));
        const ppgr = ppgio + ppgao;

        // 3rd-order physical delay (PPTD = 20.0 years)
        const pptd: f64 = 20.0;
        const delay_rate = 3.0 / pptd;

        var x1 = self.state.delay_stages[0];
        var x2 = self.state.delay_stages[1];
        var x3 = self.state.delay_stages[2];

        x1 += dt * delay_rate * (ppgr - x1);
        x2 += dt * delay_rate * (x1 - x2);
        x3 += dt * delay_rate * (x2 - x3);

        self.state.delay_stages[0] = x1;
        self.state.delay_stages[1] = x2;
        self.state.delay_stages[2] = x3;

        const ppapr = x3;

        // Ecosystem assimilation
        const ppolx = self.state.ppol / 1.36e8;
        const ahlm = 1.0 + 0.04 * @max(0.0, ppolx - 1.0);
        const ahl = ahlm * 1.5;
        const ppasr = self.state.ppol / (ahl * 1.4);

        const next_ppol = @max(0.0, self.state.ppol + dt * (ppapr - ppasr));
        const next_ppolx = next_ppol / 1.36e8;
        const lmp = interpolateLMP(next_ppolx);

        self.state.ppol = next_ppol;
        self.state.ppolx = next_ppolx;

        return .{
            .ppol = next_ppol,
            .ppolx = next_ppolx,
            .lmp = lmp,
        };
    }

    pub fn calculateMortalityMultiplier(ppolx: f64, vuln_profile: *const [104]f64) [104]f64 {
        const lmp = interpolateLMP(ppolx);
        var mult: [104]f64 = undefined;
        const base_damage = 1.0 - lmp;
        for (0..104) |i| {
            mult[i] = 1.0 + vuln_profile[i] * base_damage;
        }
        return mult;
    }
};

// =========================================================================
// Agriculture Sector Specification Engine (M3 Contract Oracle)
// =========================================================================

pub const AgricultureState = struct {
    arable_land: f64, // ha (Initial: 0.9e9)
    potentially_arable: f64, // ha (Initial: 2.3e9)
    urban_land: f64, // ha (Initial: 8.2e6)
    land_fertility: f64, // kg/(ha-yr) (Initial: 600.0)
    agricultural_inputs: f64, // $/yr (Initial: 5.0e9)
    perceived_food_ratio: f64, // Initial: 1.0
};

pub const AgricultureCurves = struct {
    food_demand_profile: [104]f64 align(64),
    starvation_vulnerability: [104]f64 align(64),
};

pub const AgricultureOutput = struct {
    food_produced: f64,
    food_per_capita: f64,
    food_ratio: f64,
    fioaa: f64,
    arable_land: f64,
    aiph: f64,
};

pub const AgricultureEngine = struct {
    state: AgricultureState,

    pub fn init() @This() {
        return .{
            .state = .{
                .arable_land = 0.9e9,
                .potentially_arable = 2.3e9,
                .urban_land = 8.2e6,
                .land_fertility = 600.0,
                .agricultural_inputs = 5.0e9,
                .perceived_food_ratio = 1.0,
            },
        };
    }

    pub fn interpolateLYMC(aiph: f64) f64 {
        if (aiph <= 0.0) return 1.0;
        if (aiph <= 80.0) return 1.0 + (aiph / 80.0) * 2.8;
        if (aiph <= 320.0) return 3.8 + ((aiph - 80.0) / 240.0) * 2.5;
        if (aiph <= 1000.0) return 6.3 + ((aiph - 320.0) / 680.0) * 3.7;
        return @min(12.0, 10.0 + ((aiph - 1000.0) / 1000.0) * 2.0);
    }

    pub fn interpolateFIOAA(ratio: f64) f64 {
        if (ratio >= 2.0) return 0.0;
        if (ratio >= 1.0) return 0.10 * (2.0 - ratio);
        if (ratio >= 0.5) return 0.10 + (1.0 - ratio) * 0.40;
        return @min(0.40, 0.30 + (0.5 - ratio) * 0.20);
    }

    pub fn step(self: *@This(), total_pop: f64, industrial_output: f64, iopc: f64, ppolx: f64, total_food_demand: f64, dt: f64) AgricultureOutput {
        _ = iopc;
        const effective_pop = @max(0.0, total_pop);
        const falm: f64 = 0.07;
        const aiph = (self.state.agricultural_inputs * (1.0 - falm)) / @max(1.0, self.state.arable_land);
        const lymc = interpolateLYMC(aiph);

        // Air pollution degradation factor LYMAP
        const lymap = @max(0.2, 1.0 - ppolx * 0.005);
        const ly = 1.0 * self.state.land_fertility * lymc * lymap;
        const food_produced = 0.63 * ly * self.state.arable_land;

        const food_per_capita = food_produced / @max(1.0, effective_pop);
        const food_ratio = food_produced / @max(1.0, total_food_demand);

        // Smooth perceived food ratio
        self.state.perceived_food_ratio += dt * 0.5 * (food_ratio - self.state.perceived_food_ratio);

        const fioaa = interpolateFIOAA(self.state.perceived_food_ratio);
        const tai = @max(0.0, industrial_output) * fioaa;

        // Update agricultural inputs smoothing (ALAI = 2.0 yr)
        self.state.agricultural_inputs += dt * 0.5 * (tai - self.state.agricultural_inputs);
        self.state.agricultural_inputs = @max(1.0e8, self.state.agricultural_inputs);

        // Land fertility degradation from pollution
        const lfdr = @min(0.5, ppolx * 0.01);
        const lfd = self.state.land_fertility * lfdr;
        const lfr = (600.0 - self.state.land_fertility) / 20.0;
        self.state.land_fertility = @max(10.0, self.state.land_fertility + dt * (lfr - lfd));

        return .{
            .food_produced = food_produced,
            .food_per_capita = food_per_capita,
            .food_ratio = food_ratio,
            .fioaa = fioaa,
            .arable_land = self.state.arable_land,
            .aiph = aiph,
        };
    }

    pub fn calculateMortalityMultiplier(food_ratio: f64, vuln_profile: *const [104]f64) [104]f64 {
        var mult: [104]f64 = undefined;
        if (food_ratio < 1.0) {
            const lmf = @max(0.02, food_ratio);
            const famine_severity = (1.0 / lmf) - 1.0;
            for (0..104) |i| {
                mult[i] = 1.0 + vuln_profile[i] * famine_severity;
            }
        } else {
            const nutrition_bonus = @min(0.3, 0.3 * ((food_ratio - 1.0) / 4.0));
            for (0..104) |i| {
                _ = vuln_profile[i];
                mult[i] = @max(0.70, 1.0 - nutrition_bonus);
            }
        }
        return mult;
    }
};

// =========================================================================
// Default Curves Generators for Collision-Zone Interfaces
// =========================================================================

pub fn generateDefaultResourceCurves() ResourceCurves {
    var curves = ResourceCurves{
        .resource_usage_profile = [_]f64{0.0} ** 104,
    };
    for (0..104) |age| {
        const a: f64 = @floatFromInt(age);
        if (age < 18) {
            curves.resource_usage_profile[age] = 0.2 + (a / 18.0) * 0.8;
        } else if (age <= 65) {
            curves.resource_usage_profile[age] = 1.0;
        } else {
            const drop = (a - 65.0) / 38.0;
            curves.resource_usage_profile[age] = @max(0.4, 1.0 - drop * 0.6);
        }
    }
    return curves;
}

pub fn generateDefaultPollutionCurves() PollutionCurves {
    var curves = PollutionCurves{
        .vulnerability_profile = [_]f64{1.0} ** 104,
    };
    for (0..104) |age| {
        if (age <= 2) {
            curves.vulnerability_profile[age] = 3.0;
        } else if (age <= 14) {
            const t = @as(f64, @floatFromInt(age - 2)) / 12.0;
            curves.vulnerability_profile[age] = 3.0 - t * 2.2;
        } else if (age <= 45) {
            curves.vulnerability_profile[age] = 0.5;
        } else if (age <= 69) {
            const t = @as(f64, @floatFromInt(age - 45)) / 24.0;
            curves.vulnerability_profile[age] = 0.5 + t * 1.5;
        } else {
            const t = @min(1.0, @as(f64, @floatFromInt(age - 69)) / 34.0);
            curves.vulnerability_profile[age] = 2.0 + t * 2.0;
        }
    }
    return curves;
}

pub fn generateDefaultAgricultureCurves() AgricultureCurves {
    var curves = AgricultureCurves{
        .food_demand_profile = [_]f64{230.0} ** 104,
        .starvation_vulnerability = [_]f64{1.0} ** 104,
    };
    for (0..104) |age| {
        const a: f64 = @floatFromInt(age);
        if (age <= 2) {
            curves.food_demand_profile[age] = 80.0;
        } else if (age <= 12) {
            curves.food_demand_profile[age] = 80.0 + (a - 2.0) * (80.0 / 10.0);
        } else if (age <= 64) {
            curves.food_demand_profile[age] = 230.0;
        } else {
            curves.food_demand_profile[age] = 180.0;
        }

        if (age <= 4) {
            curves.starvation_vulnerability[age] = 3.5 - (a / 4.0) * 1.0;
        } else if (age <= 17) {
            curves.starvation_vulnerability[age] = 1.2 - ((a - 5.0) / 12.0) * 0.4;
        } else if (age <= 55) {
            curves.starvation_vulnerability[age] = 0.6;
        } else if (age <= 74) {
            curves.starvation_vulnerability[age] = 0.6 + ((a - 55.0) / 19.0) * 1.4;
        } else {
            curves.starvation_vulnerability[age] = 2.0 + ((a - 75.0) / 28.0) * 2.0;
        }
    }
    return curves;
}

// =========================================================================
// Unified Synchronous 5-Sector Simulation Harness
// =========================================================================

pub const SimulationContext = struct {
    dem: Demographics,
    econ: EconomyEngine,
    rsc: ResourceEngine,
    pol: PollutionEngine,
    agr: AgricultureEngine,

    econ_curves: EconomyCurves,
    rsc_curves: ResourceCurves,
    pol_curves: PollutionCurves,
    agr_curves: AgricultureCurves,

    pub fn init() SimulationContext {
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
            .econ_curves = generateDefaultEconomyCurves(),
            .rsc_curves = generateDefaultResourceCurves(),
            .pol_curves = generateDefaultPollutionCurves(),
            .agr_curves = generateDefaultAgricultureCurves(),
        };
    }
};

pub const StepOutput = struct {
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
};

pub fn step5Sectors(
    ctx: *SimulationContext,
    asfr: *const [104]f64,
    base_mort_m: *const [104]f64,
    base_mort_f: *const [104]f64,
    dt: f64,
) StepOutput {
    // 1. Gather Demographic Totals
    const total_pop = ctx.dem.state.total_pop;
    var total_labor: f64 = 0.0;
    var total_food_demand: f64 = 0.0;
    for (0..104) |age| {
        const cohort_pop = ctx.dem.state.males[age] + ctx.dem.state.females[age];
        total_labor += cohort_pop * ctx.econ_curves.labor_participation[age];
        total_food_demand += cohort_pop * ctx.agr_curves.food_demand_profile[age];
    }

    // 2. Economy Step (gated by Resource Extraction Drag FCAOR)
    const effective_ic = ctx.econ.state.industrial_capital * (1.0 - ctx.rsc.state.fcaor);
    const industrial_output = (@max(0.0, effective_ic) * 0.13184) * (total_labor / 1_000_000_000.0);
    const services_output = (ctx.econ.state.service_capital * 0.22111) * (total_labor / 1_000_000_000.0);
    var total_energy: f64 = 0.0;
    for (0..104) |age| {
        const cohort_pop = ctx.dem.state.males[age] + ctx.dem.state.females[age];
        total_energy += cohort_pop * ctx.econ_curves.energy_demand_profile[age];
    }
    const iopc = industrial_output / @max(1.0, total_pop);

    // 3. Resources Step
    const rsc_out = ctx.rsc.step(total_pop, iopc, dt);

    // 4. Agriculture Step
    const agr_out = ctx.agr.step(total_pop, industrial_output, iopc, ctx.pol.state.ppolx, total_food_demand, dt);

    // 5. Pollution Step
    const pol_out = ctx.pol.step(total_pop, rsc_out.pcrum, agr_out.aiph, agr_out.arable_land, dt);

    // 6. Demographics Interface: Vectorized Composite Mortality Update
    const food_mort = AgricultureEngine.calculateMortalityMultiplier(agr_out.food_ratio, &ctx.agr_curves.starvation_vulnerability);
    const poll_mort = PollutionEngine.calculateMortalityMultiplier(pol_out.ppolx, &ctx.pol_curves.vulnerability_profile);

    var eff_mort_m: [104]f64 = undefined;
    var eff_mort_f: [104]f64 = undefined;
    for (0..104) |age| {
        const combined_mult = food_mort[age] * poll_mort[age];
        eff_mort_m[age] = @min(1.0, @max(0.0, base_mort_m[age] * combined_mult));
        eff_mort_f[age] = @min(1.0, @max(0.0, base_mort_f[age] * combined_mult));
    }

    // 7. Demographics Step
    ctx.dem.step(asfr.*, eff_mort_m, eff_mort_f);

    return .{
        .total_pop = ctx.dem.state.total_pop,
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
    };
}

// =========================================================================
// Numerical & Demographic Safety Validators
// =========================================================================

pub fn assertDemographicSafety(dem: *const Demographics) !void {
    if (std.math.isNan(dem.state.total_pop)) return error.NanPopulation;
    if (std.math.isInf(dem.state.total_pop)) return error.InfPopulation;
    if (dem.state.total_pop < 0.0) return error.NegativePopulation;

    for (dem.state.males) |m| {
        if (std.math.isNan(m)) return error.NanMaleCohort;
        if (std.math.isInf(m)) return error.InfMaleCohort;
        if (m < 0.0) return error.NegativeMaleCohort;
    }
    for (dem.state.females) |f| {
        if (std.math.isNan(f)) return error.NanFemaleCohort;
        if (std.math.isInf(f)) return error.InfFemaleCohort;
        if (f < 0.0) return error.NegativeFemaleCohort;
    }
    if (std.math.isNan(dem.state.births) or dem.state.births < 0.0) return error.InvalidBirths;
    if (std.math.isNan(dem.state.deaths) or dem.state.deaths < 0.0) return error.InvalidDeaths;
}

pub fn assertOutputSafety(out: *const StepOutput) !void {
    if (std.math.isNan(out.total_pop) or std.math.isInf(out.total_pop)) return error.InvalidPop;
    if (std.math.isNan(out.industrial_output) or std.math.isInf(out.industrial_output)) return error.InvalidIO;
    if (std.math.isNan(out.services_output) or std.math.isInf(out.services_output)) return error.InvalidSO;
    if (std.math.isNan(out.energy_twh) or std.math.isInf(out.energy_twh)) return error.InvalidEnergy;
    if (std.math.isNan(out.remaining_resources) or out.remaining_resources < 0.0) return error.InvalidResources;
    if (std.math.isNan(out.fcaor) or out.fcaor < 0.0 or out.fcaor > 1.0) return error.InvalidFCAOR;
    if (std.math.isNan(out.ppol) or out.ppol < 0.0) return error.InvalidPPOL;
    if (std.math.isNan(out.food_produced) or out.food_produced < 0.0) return error.InvalidFood;
}

test "harness self check" {
    const ctx = SimulationContext.init();
    try std.testing.expect(ctx.dem.state.total_pop > 7.0e9);
    try std.testing.expect(ctx.rsc.state.remaining_resources == 1.0e12);
    try std.testing.expect(ctx.pol.state.ppol == 2.5e7);
    try std.testing.expect(ctx.agr.state.arable_land == 0.9e9);
}
