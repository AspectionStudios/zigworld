const std = @import("std");

/// The state of the Agriculture sector (PROJECT.md § Interface Contracts).
/// Plain Old Data (POD) struct: 48 bytes, natural alignment 8 (fits within a single 64-byte L1 cache line).
pub const AgricultureState = struct {
    arable_land: f64,          // ha (Initial: 0.9e9)
    potentially_arable: f64,   // ha (Initial: 2.3e9)
    urban_land: f64,           // ha (Initial: 8.2e6)
    land_fertility: f64,       // kg/(ha-yr) (Initial: 600.0)
    agricultural_inputs: f64,  // $/yr (Initial: 5.0e9)
    perceived_food_ratio: f64, // Initial: 1.0 (smoothed food availability ratio)
};

/// Hardware-aligned age-specific food demand and starvation vulnerability profiles (PROJECT.md § Interface Contracts).
/// Padded to exactly 104 f64 elements each (832 bytes each = 13 x 64-byte L1 cache lines, align(64)).
pub const AgricultureCurves = struct {
    food_demand_profile: [104]f64 align(64),      // kg/person-yr (infants: 80, adults: 230)
    starvation_vulnerability: [104]f64 align(64), // age-specific famine susceptibility
};

/// Step output returned by value (PROJECT.md § Interface Contracts).
/// POD struct: 48 bytes, natural alignment 8 (fits within a single 64-byte cache line).
pub const AgricultureOutput = struct {
    food_produced: f64,   // Total food harvested (kg/yr, >= 0.0)
    food_per_capita: f64, // Average food per person (kg/person-yr, >= 0.0)
    food_ratio: f64,      // Ratio of food produced to total demand (>= 0.0)
    fioaa: f64,           // Fraction of industrial output allocated to agriculture [0.0, 0.40]
    arable_land: f64,     // Active arable land (ha, >= 0.0)
    aiph: f64,            // Agricultural inputs per hectare ($/ha-yr, >= 0.0)
};

/// High-speed safe division preventing NaN, Inf, and division-by-zero.
pub inline fn safeDiv(numerator: f64, denominator: f64, fallback: f64) f64 {
    const min_denom: f64 = 1.0e-12;
    if (@abs(denominator) < min_denom or
        std.math.isNan(denominator) or
        std.math.isNan(numerator) or
        std.math.isInf(denominator) or
        std.math.isInf(numerator))
    {
        return fallback;
    }
    const res = numerator / denominator;
    return if (std.math.isNan(res) or std.math.isInf(res)) fallback else res;
}

/// Sanitize floating-point inputs against NaN, Inf, and negative values.
pub inline fn sanitizeNonNegative(val: f64) f64 {
    if (std.math.isNan(val) or std.math.isInf(val)) return 0.0;
    return @max(0.0, val);
}

/// The Agriculture & Food Engine (PROJECT.md § Interface Contracts)
pub const AgricultureEngine = struct {
    state: AgricultureState,

    // Initial Physical Constants (World3 Standard Calibration)
    pub const INITIAL_ARABLE_LAND: f64 = 0.9e9;        // ha (AL)
    pub const INITIAL_POTENTIALLY_ARABLE: f64 = 2.3e9;  // ha (PAL)
    pub const INITIAL_URBAN_LAND: f64 = 8.2e6;         // ha (UIL)
    pub const INITIAL_LAND_FERTILITY: f64 = 600.0;     // kg/(ha-yr) (LFERTI)
    pub const INITIAL_AGRICULTURAL_INPUTS: f64 = 5.0e9;// $/yr (AII)
    pub const INITIAL_FOOD_RATIO: f64 = 1.0;           // Baseline (FR)
    pub const TOTAL_LAND_CONSERVATION: f64 = 3.2082e9; // Total planetary land stock (ha)

    // Operational Parameters
    pub const FALM: f64 = 0.07;           // Fraction of inputs allocated to land maintenance (0.07)
    pub const HARVEST_EFFICIENCY: f64 = 0.63; // Harvest and processing net factor
    pub const ALAI: f64 = 2.0;            // Agricultural inputs averaging time (years)
    pub const ILF: f64 = 600.0;           // Inherent land fertility baseline (kg/ha-yr)
    pub const PFRT: f64 = 2.0;            // Perceived food ratio smoothing time (years)
    pub const MIN_AGRICULTURAL_INPUTS: f64 = 1.0e8; // Minimum inputs floor ($100M/yr)
    pub const MIN_LAND_FERTILITY: f64 = 10.0;       // Minimum fertility floor (10 kg/ha-yr)

    pub fn init() AgricultureEngine {
        return AgricultureEngine{
            .state = .{
                .arable_land = INITIAL_ARABLE_LAND,
                .potentially_arable = INITIAL_POTENTIALLY_ARABLE,
                .urban_land = INITIAL_URBAN_LAND,
                .land_fertility = INITIAL_LAND_FERTILITY,
                .agricultural_inputs = INITIAL_AGRICULTURAL_INPUTS,
                .perceived_food_ratio = INITIAL_FOOD_RATIO,
            },
        };
    }

    /// Piecewise linear interpolation for Land Yield Multiplier from Capital (LYMC).
    /// Bounded in [1.0, 12.0]. Rejects NaN, Inf, and negative values.
    pub inline fn interpolateLYMC(aiph: f64) f64 {
        if (std.math.isNan(aiph) or aiph <= 0.0) return 1.0;
        if (std.math.isInf(aiph)) return 12.0;

        if (aiph <= 80.0) {
            return 1.0 + (aiph / 80.0) * 2.8;
        } else if (aiph <= 320.0) {
            return 3.8 + ((aiph - 80.0) / 240.0) * 2.5;
        } else if (aiph <= 1000.0) {
            return 6.3 + ((aiph - 320.0) / 680.0) * 3.7;
        } else {
            return @min(12.0, 10.0 + ((aiph - 1000.0) / 1000.0) * 2.0);
        }
    }

    /// Piecewise linear interpolation for Fraction of Industrial Output Allocated to Agriculture (FIOAA).
    /// Bounded in [0.0, 0.40]. Rejects NaN, Inf, and negative values.
    pub inline fn interpolateFIOAA(ratio: f64) f64 {
        if (std.math.isNan(ratio)) return 0.10; // Baseline fallback
        if (ratio >= 2.0) return 0.0;
        if (ratio >= 1.0) return 0.10 * (2.0 - ratio);
        if (ratio >= 0.5) return 0.10 + (1.0 - ratio) * 0.40;
        if (ratio <= 0.0) return 0.40;
        return @min(0.40, 0.30 + (0.5 - ratio) * 0.20);
    }

    /// Execute a single simulation step.
    /// total_pop: Total active human population (>= 0.0)
    /// industrial_output: Total industrial output ($/year)
    /// iopc: Industrial Output Per Capita ($/person-year)
    /// ppolx: Normalized persistent pollution index (>= 0.0)
    /// total_food_demand: Total aggregate food demand (kg/year, >= 0.0)
    /// dt: Time step in years (default 1.0)
    pub fn step(
        self: *@This(),
        total_pop: f64,
        industrial_output: f64,
        iopc: f64,
        ppolx: f64,
        total_food_demand: f64,
        dt: f64,
    ) AgricultureOutput {
        _ = iopc; // Used in extended demographic tracking

        // Guardrail 1: Sanitize all inputs against negative values, NaN, and Inf
        const safe_pop = sanitizeNonNegative(total_pop);
        const safe_io = sanitizeNonNegative(industrial_output);
        const safe_ppolx = sanitizeNonNegative(ppolx);
        const safe_demand = sanitizeNonNegative(total_food_demand);
        const safe_dt = sanitizeNonNegative(dt);

        // Guardrail 2: Bound existing state variables
        const current_al = @max(0.0, self.state.arable_land);
        const current_fert = @max(MIN_LAND_FERTILITY, self.state.land_fertility);
        const current_ai = @max(MIN_AGRICULTURAL_INPUTS, self.state.agricultural_inputs);
        const current_pfr = @max(0.0, self.state.perceived_food_ratio);

        // 1. Agricultural Inputs per Hectare (AIPH)
        // Guardrail: When arable land is 0, intensity is 0 (prevents division by zero)
        const aiph = if (current_al <= 0.0)
            0.0
        else
            safeDiv(current_ai * (1.0 - FALM), current_al, 0.0);

        // 2. Capital Yield Multiplier (LYMC)
        const lymc = AgricultureEngine.interpolateLYMC(aiph);

        // 3. Air Pollution Degradation Factor (LYMAP)
        // Pollution suppresses crop photosynthesis: drops from 1.0 to 0.2 under acute smog
        const lymap = @max(0.2, 1.0 - safe_ppolx * 0.005);

        // 4. Land Yield (LY) in kg/(ha-yr)
        const ly = current_fert * lymc * lymap;

        // 5. Total Food Produced (F) in kg/yr
        // Guardrail: Zero arable land yields exactly zero food
        const food_produced = if (current_al <= 0.0)
            0.0
        else
            @max(0.0, HARVEST_EFFICIENCY * ly * current_al);

        // 6. Food Per Capita & Food Ratio
        // Guardrail: Safe denominators using safeDiv and @max floors
        const food_per_capita = if (safe_pop <= 0.0)
            0.0
        else
            safeDiv(food_produced, @max(1.0, safe_pop), 0.0);

        const food_ratio = if (safe_demand <= 0.0)
            (if (food_produced == 0.0) 1.0 else safeDiv(food_produced, 1.0, 1.0))
        else
            safeDiv(food_produced, safe_demand, 1.0);

        // 7. Perceived Food Ratio (PFR) Smoothing ODE (tau = 2.0 years)
        const next_pfr = @max(0.0, current_pfr + safe_dt * 0.5 * (food_ratio - current_pfr));
        self.state.perceived_food_ratio = next_pfr;

        // 8. Capital Allocation Feedback (FIOAA)
        const fioaa = AgricultureEngine.interpolateFIOAA(next_pfr);
        const tai = safe_io * fioaa;

        // 9. Agricultural Inputs Smoothing ODE (ALAI = 2.0 years)
        const next_ai = @max(MIN_AGRICULTURAL_INPUTS, current_ai + safe_dt * 0.5 * (tai - current_ai));
        self.state.agricultural_inputs = next_ai;

        // 10. Land Fertility Dynamics ODE (Regeneration vs Pollution Degradation)
        // LFDR: Land fertility degradation rate fraction [0.0, 0.5]
        const lfdr = @min(0.5, safe_ppolx * 0.01);
        const lfd = current_fert * lfdr; // Degradation loss
        const lfr = (ILF - current_fert) / 20.0; // Natural 20-year biological regeneration
        const next_fert = @max(MIN_LAND_FERTILITY, current_fert + safe_dt * (lfr - lfd));
        self.state.land_fertility = next_fert;

        // Arable land remains conserved
        self.state.arable_land = current_al;

        return AgricultureOutput{
            .food_produced = food_produced,
            .food_per_capita = food_per_capita,
            .food_ratio = food_ratio,
            .fioaa = fioaa,
            .arable_land = current_al,
            .aiph = aiph,
        };
    }

    /// Collision-Zone demographic interface: computes age-specific food mortality multiplier vector.
    /// Under starvation (food_ratio < 1.0):
    ///   LMF = @max(0.02, food_ratio)
    ///   famine_severity = (1.0 / LMF) - 1.0
    ///   M_mult,food[age] = 1.0 + V_starv[age] * famine_severity
    /// Under abundance (food_ratio >= 1.0):
    ///   nutrition_bonus = @min(0.3, 0.3 * (food_ratio - 1.0) / 4.0)
    ///   M_mult,food[age] = @max(0.70, 1.0 - nutrition_bonus)
    pub fn calculateMortalityMultiplier(food_ratio: f64, vuln_profile: *const [104]f64) [104]f64 {
        var mult: [104]f64 = undefined;

        if (std.math.isNan(food_ratio) or food_ratio < 1.0) {
            const safe_fr = if (std.math.isNan(food_ratio)) 0.02 else @max(0.0, food_ratio);
            const lmf = @max(0.02, safe_fr);
            const famine_severity = (1.0 / lmf) - 1.0;
            for (0..104) |i| {
                const v = @max(0.0, vuln_profile[i]);
                mult[i] = @max(1.0, 1.0 + v * famine_severity);
            }
        } else {
            const safe_fr = if (std.math.isInf(food_ratio)) 10.0 else food_ratio;
            const nutrition_bonus = @min(0.3, 0.3 * ((safe_fr - 1.0) / 4.0));
            const base_mort = @max(0.70, 1.0 - nutrition_bonus);
            for (0..104) |i| {
                _ = vuln_profile[i];
                mult[i] = base_mort;
            }
        }
        return mult;
    }

    /// Collision-Zone demographic interface: aggregates total age-specific food demand.
    pub fn calculateTotalFoodDemand(
        males: *const [104]f64,
        females: *const [104]f64,
        curves: *const AgricultureCurves,
    ) f64 {
        var total_demand: f64 = 0.0;
        for (0..104) |i| {
            const pop_cohort = @max(0.0, males[i]) + @max(0.0, females[i]);
            total_demand += pop_cohort * @max(0.0, curves.food_demand_profile[i]);
        }
        return @max(0.0, total_demand);
    }

    /// Direct helper to obtain default curves from AgricultureEngine
    pub fn generateDefaultCurves() AgricultureCurves {
        return generateDefaultAgricultureCurves();
    }
};

/// Top-level functional exports matching project conventions
pub const interpolateLYMC = AgricultureEngine.interpolateLYMC;
pub const interpolateFIOAA = AgricultureEngine.interpolateFIOAA;
pub const calculateMortalityMultiplier = AgricultureEngine.calculateMortalityMultiplier;
pub const calculateTotalFoodDemand = AgricultureEngine.calculateTotalFoodDemand;

/// Default AgricultureCurves generation matching Collision-Zone life-cycle profiles.
pub fn generateDefaultCurves() AgricultureCurves {
    var curves = AgricultureCurves{
        .food_demand_profile = undefined,
        .starvation_vulnerability = undefined,
    };
    for (0..104) |age| {
        const a: f64 = @floatFromInt(age);

        // Caloric demand profile (infants: 80 kg, teens/adults: 230 kg, elderly: 180 kg)
        if (age <= 2) {
            curves.food_demand_profile[age] = 80.0;
        } else if (age <= 12) {
            curves.food_demand_profile[age] = 80.0 + (a - 2.0) * (80.0 / 10.0);
        } else if (age <= 64) {
            curves.food_demand_profile[age] = 230.0;
        } else {
            curves.food_demand_profile[age] = 180.0;
        }

        // Starvation vulnerability profile (infants: 3.5, adults: 0.6, elderly: 2.0 -> 4.0)
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

pub const generateDefaultAgricultureCurves = generateDefaultCurves;

// ============================================================================
// EMBEDDED UNIT TEST SUITE (12 COMPREHENSIVE TESTS)
// ============================================================================

test "AgricultureEngine: 1. Initial 1900 benchmark calibration & land conservation" {
    const engine = AgricultureEngine.init();

    // Verify initial stock values
    try std.testing.expectEqual(@as(f64, 0.9e9), engine.state.arable_land);
    try std.testing.expectEqual(@as(f64, 2.3e9), engine.state.potentially_arable);
    try std.testing.expectEqual(@as(f64, 8.2e6), engine.state.urban_land);
    try std.testing.expectEqual(@as(f64, 600.0), engine.state.land_fertility);
    try std.testing.expectEqual(@as(f64, 5.0e9), engine.state.agricultural_inputs);
    try std.testing.expectEqual(@as(f64, 1.0), engine.state.perceived_food_ratio);

    // Total planetary land conservation invariant
    const total_land = engine.state.arable_land + engine.state.potentially_arable + engine.state.urban_land;
    try std.testing.expectApproxEqAbs(AgricultureEngine.TOTAL_LAND_CONSERVATION, total_land, 1.0);

    // Step under 1900 baseline conditions
    var sim = engine;
    const pop_1900: f64 = 1.65e9;
    const io_1900: f64 = 30.0e9;
    const iopc_1900: f64 = 18.18;
    const ppolx_1900: f64 = 0.1838;
    const demand_1900: f64 = pop_1900 * 230.0; // ~3.795e11 kg
    const dt: f64 = 1.0;

    const out = sim.step(pop_1900, io_1900, iopc_1900, ppolx_1900, demand_1900, dt);

    // Positive finite production
    try std.testing.expect(out.food_produced > 0.0);
    try std.testing.expect(out.food_per_capita > 0.0);
    try std.testing.expect(out.food_ratio > 0.0);
    try std.testing.expect(out.fioaa > 0.0 and out.fioaa <= 0.20);
    try std.testing.expect(out.aiph > 0.0);
    try std.testing.expectEqual(@as(f64, 0.9e9), out.arable_land);
    try std.testing.expect(!std.math.isNan(out.food_produced));
    try std.testing.expect(!std.math.isInf(out.food_produced));
}

test "AgricultureEngine: 2. Fertile vs degraded land production dynamics" {
    var agr_fertile = AgricultureEngine.init();
    var agr_degraded = AgricultureEngine.init();

    // Pristine conditions
    agr_fertile.state.land_fertility = 600.0;
    // Severely degraded soil under acute pollution
    agr_degraded.state.land_fertility = 50.0;

    const pop = 8.0e9;
    const io = 30.0e12;
    const demand = 8.0e9 * 230.0;

    const out_fertile = agr_fertile.step(pop, io, 3750.0, 0.0, demand, 1.0);
    const out_degraded = agr_degraded.step(pop, io, 3750.0, 50.0, demand, 1.0); // High pollution

    // Fertile pristine land must produce vastly more food than degraded polluted land
    try std.testing.expect(out_fertile.food_produced > 5.0 * out_degraded.food_produced);
    try std.testing.expect(out_fertile.food_per_capita > 5.0 * out_degraded.food_per_capita);
    try std.testing.expect(out_fertile.food_ratio > out_degraded.food_ratio);
}

test "AgricultureEngine: 3. Zero food famine shock & mortality multiplier explosion" {
    const curves = generateDefaultCurves();

    // Absolute crop failure (food_ratio = 0.0)
    const famine_mort = AgricultureEngine.calculateMortalityMultiplier(0.0, &curves.starvation_vulnerability);

    // Bounded, finite, non-NaN and non-Inf across all cohorts
    for (famine_mort) |m| {
        try std.testing.expect(!std.math.isNan(m));
        try std.testing.expect(!std.math.isInf(m));
        try std.testing.expect(m > 1.0);
    }

    // Mathematical verification:
    // LMF floor = 0.02 -> famine_severity = (1.0 / 0.02) - 1.0 = 49.0
    // Infant (age 0, vuln = 3.5): mult = 1.0 + 3.5 * 49.0 = 172.5
    try std.testing.expectApproxEqAbs(@as(f64, 172.5), famine_mort[0], 1.0e-6);

    // Prime Adult (age 30, vuln = 0.6): mult = 1.0 + 0.6 * 49.0 = 30.4
    try std.testing.expectApproxEqAbs(@as(f64, 30.4), famine_mort[30], 1.0e-6);

    // Elderly (age 80, vuln > 2.0): mult > 100.0
    try std.testing.expect(famine_mort[80] > 100.0);
}

test "AgricultureEngine: 4. Extreme abundance saturation (FR >= 5.0, FR = 10.0)" {
    const curves = generateDefaultCurves();

    // Super-abundance food ratio: FR = 10.0
    const surplus_mort = AgricultureEngine.calculateMortalityMultiplier(10.0, &curves.starvation_vulnerability);

    // Invariant: Multipliers must all be exactly clamped to 0.70 (30% mortality reduction)
    for (surplus_mort) |m| {
        try std.testing.expect(!std.math.isNan(m));
        try std.testing.expect(!std.math.isInf(m));
        try std.testing.expectApproxEqAbs(@as(f64, 0.70), m, 1.0e-9);
    }

    // Intermediate surplus: FR = 3.0 -> bonus = 0.3 * (2.0 / 4.0) = 0.15 -> mult = 0.85
    const mid_surplus = AgricultureEngine.calculateMortalityMultiplier(3.0, &curves.starvation_vulnerability);
    for (mid_surplus) |m| {
        try std.testing.expectApproxEqAbs(@as(f64, 0.85), m, 1.0e-6);
    }
}

test "AgricultureEngine: 5. Infant vs adult starvation mortality differential" {
    const curves = generateDefaultCurves();

    // Moderate famine: food_ratio = 0.5
    const mod_famine = AgricultureEngine.calculateMortalityMultiplier(0.5, &curves.starvation_vulnerability);

    // Infant excess mortality vs adult excess mortality
    // famine_severity = (1.0 / 0.5) - 1.0 = 1.0
    // Infant mult = 1.0 + 3.5 * 1.0 = 4.5
    // Adult mult = 1.0 + 0.6 * 1.0 = 1.6
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), mod_famine[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 1.6), mod_famine[30], 1.0e-6);

    // Excess ratio: (4.5 - 1.0) / (1.6 - 1.0) = 3.5 / 0.6 ~ 5.8333
    const infant_excess = mod_famine[0] - 1.0;
    const adult_excess = mod_famine[30] - 1.0;
    try std.testing.expectApproxEqAbs(@as(f64, 3.5 / 0.6), infant_excess / adult_excess, 1.0e-6);

    // Monotonicity check: as food ratio worsens, mortality must monotonically increase
    const fr_sequence = [_]f64{ 1.0, 0.8, 0.6, 0.4, 0.2, 0.05, 0.0 };
    var prev_infant_mort: f64 = 0.0;
    for (fr_sequence) |fr| {
        const m = AgricultureEngine.calculateMortalityMultiplier(fr, &curves.starvation_vulnerability);
        try std.testing.expect(m[0] >= prev_infant_mort);
        prev_infant_mort = m[0];
    }
}

test "AgricultureEngine: 6. FIOAA capital feedback & economic emergency response" {
    // Exact table knot assertions
    try std.testing.expectEqual(@as(f64, 0.0), AgricultureEngine.interpolateFIOAA(2.5));
    try std.testing.expectEqual(@as(f64, 0.0), AgricultureEngine.interpolateFIOAA(2.0));
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), AgricultureEngine.interpolateFIOAA(1.5), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.10), AgricultureEngine.interpolateFIOAA(1.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.20), AgricultureEngine.interpolateFIOAA(0.75), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.30), AgricultureEngine.interpolateFIOAA(0.50), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.32), AgricultureEngine.interpolateFIOAA(0.40), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.40), AgricultureEngine.interpolateFIOAA(0.00), 1.0e-9);

    // Step engine with perceived famine
    var agr = AgricultureEngine.init();
    agr.state.perceived_food_ratio = 0.4;
    const out = agr.step(8.0e9, 30.0e12, 3750.0, 1.0, 8.0e9 * 230.0, 1.0);
    try std.testing.expect(out.fioaa >= 0.30);
}

test "AgricultureEngine: 7. Input yield multiplier (LYMC) table knot exactness & saturation" {
    // Official World3 table knots
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), AgricultureEngine.interpolateLYMC(0.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.8), AgricultureEngine.interpolateLYMC(80.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 6.3), AgricultureEngine.interpolateLYMC(320.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), AgricultureEngine.interpolateLYMC(1000.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 12.0), AgricultureEngine.interpolateLYMC(2000.0), 1.0e-9);

    // Linear midpoints
    try std.testing.expectApproxEqAbs(@as(f64, 2.4), AgricultureEngine.interpolateLYMC(40.0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 5.05), AgricultureEngine.interpolateLYMC(200.0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 8.15), AgricultureEngine.interpolateLYMC(660.0), 1.0e-6);

    // Saturation and adversarial extremes
    try std.testing.expectEqual(@as(f64, 12.0), AgricultureEngine.interpolateLYMC(10_000.0));
    try std.testing.expectEqual(@as(f64, 12.0), AgricultureEngine.interpolateLYMC(100_000.0));
    try std.testing.expectEqual(@as(f64, 1.0), AgricultureEngine.interpolateLYMC(-100.0));
    try std.testing.expectEqual(@as(f64, 1.0), AgricultureEngine.interpolateLYMC(std.math.nan(f64)));
    try std.testing.expectEqual(@as(f64, 12.0), AgricultureEngine.interpolateLYMC(std.math.inf(f64)));
}

test "AgricultureEngine: 8. Long-term multi-century ODE conservation & soil fertility recovery" {
    var agr = AgricultureEngine.init();
    const pop: f64 = 5.0e9;
    const io: f64 = 10.0e12;
    const demand: f64 = pop * 230.0;

    // Simulate 200 years under clean conditions (ppolx = 0.0)
    for (0..200) |_| {
        _ = agr.step(pop, io, 2000.0, 0.0, demand, 1.0);
    }

    // Fertility must remain balanced at healthy biological baseline (600.0)
    try std.testing.expectApproxEqAbs(@as(f64, 600.0), agr.state.land_fertility, 1.0e-2);
    try std.testing.expect(agr.state.agricultural_inputs > 1.0e9);

    // Induce severe pollution shock for 30 years (ppolx = 50.0 -> lfdr = 0.5)
    for (0..30) |_| {
        _ = agr.step(pop, io, 2000.0, 50.0, demand, 1.0);
    }
    // Soil fertility has degraded significantly
    const degraded_fert = agr.state.land_fertility;
    try std.testing.expect(degraded_fert < 500.0);

    // Remove pollution (ppolx = 0.0) and observe recovery for 100 years
    for (0..100) |_| {
        _ = agr.step(pop, io, 2000.0, 0.0, demand, 1.0);
    }
    // Soil fertility regenerates smoothly toward 600.0
    try std.testing.expect(agr.state.land_fertility > degraded_fert);
    try std.testing.expect(agr.state.land_fertility <= 600.0);
}

test "AgricultureEngine: 9. Zero arable land resilience (AL = 0.0)" {
    var agr = AgricultureEngine.init();
    agr.state.arable_land = 0.0;

    const out = agr.step(8.0e9, 30.0e12, 3750.0, 1.0, 8.0e9 * 230.0, 1.0);

    // Must yield exactly 0.0 food produced and 0.0 per capita without NaN or Inf
    try std.testing.expectEqual(@as(f64, 0.0), out.food_produced);
    try std.testing.expectEqual(@as(f64, 0.0), out.food_per_capita);
    try std.testing.expectEqual(@as(f64, 0.0), out.aiph);
    try std.testing.expect(!std.math.isNan(out.food_ratio));
    try std.testing.expect(!std.math.isInf(out.food_ratio));
    try std.testing.expectEqual(@as(f64, 0.0), out.arable_land);
}

test "AgricultureEngine: 10. Zero food demand & zero population resilience" {
    var agr = AgricultureEngine.init();

    const out = agr.step(0.0, 0.0, 0.0, 0.0, 0.0, 1.0);

    // Must remain finite, non-NaN, non-Inf
    try std.testing.expect(!std.math.isNan(out.food_ratio));
    try std.testing.expect(!std.math.isInf(out.food_ratio));
    try std.testing.expectEqual(@as(f64, 0.0), out.food_per_capita);
    try std.testing.expect(!std.math.isNan(out.food_produced));
    try std.testing.expect(!std.math.isInf(out.food_produced));
}

test "AgricultureEngine: 11. Adversarial resilience (NaN, Inf, negative inputs, safeDiv)" {
    var agr = AgricultureEngine.init();
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);

    // Negative inputs sanitized
    const out_neg = agr.step(-10.0, -10.0, -10.0, -10.0, -10.0, 1.0);
    try std.testing.expect(out_neg.food_produced >= 0.0);
    try std.testing.expect(out_neg.food_per_capita >= 0.0);
    try std.testing.expect(out_neg.food_ratio >= 0.0);
    try std.testing.expect(out_neg.fioaa >= 0.0);

    // Negative dt must not cause backwards time travel
    const fert_before = agr.state.land_fertility;
    _ = agr.step(1.0e9, 1.0e12, 1000.0, 1.0, 1.0e11, -1.0);
    try std.testing.expectEqual(fert_before, agr.state.land_fertility);

    // NaN / Inf inputs do not corrupt state
    const out_nan = agr.step(nan, nan, nan, nan, nan, 1.0);
    try std.testing.expect(!std.math.isNan(out_nan.food_produced));
    try std.testing.expect(!std.math.isNan(out_nan.food_ratio));
    try std.testing.expect(!std.math.isNan(agr.state.land_fertility));
    try std.testing.expect(!std.math.isNan(agr.state.agricultural_inputs));

    const out_inf = agr.step(inf, inf, inf, inf, inf, 1.0);
    try std.testing.expect(!std.math.isNan(out_inf.food_produced));
    try std.testing.expect(!std.math.isInf(out_inf.food_produced));

    // safeDiv unit verification
    try std.testing.expectEqual(@as(f64, 42.0), safeDiv(100.0, 0.0, 42.0));
    try std.testing.expectEqual(@as(f64, 42.0), safeDiv(nan, 10.0, 42.0));
    try std.testing.expectEqual(@as(f64, 42.0), safeDiv(10.0, nan, 42.0));
    try std.testing.expectEqual(@as(f64, 42.0), safeDiv(10.0, inf, 42.0));
    try std.testing.expectEqual(@as(f64, 5.0), safeDiv(50.0, 10.0, 42.0));
}

test "AgricultureEngine: 12. POD memory layout, zero allocation, and sub-50ns step latency" {
    // Struct size assertions
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(AgricultureState));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(AgricultureOutput));
    try std.testing.expectEqual(@as(usize, 1664), @sizeOf(AgricultureCurves));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(AgricultureEngine));

    // Alignment assertions
    try std.testing.expectEqual(@as(usize, 8), @alignOf(AgricultureState));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(AgricultureOutput));
    try std.testing.expectEqual(@as(usize, 64), @alignOf(AgricultureCurves));

    // Field count checks matching E2E Tier 2 assertions
    try std.testing.expect(@typeInfo(AgricultureState).Struct.fields.len == 6);
    try std.testing.expect(@typeInfo(AgricultureOutput).Struct.fields.len == 6);

    // Vector food demand calculation test
    const curves = generateDefaultCurves();
    var males = [_]f64{100_000.0} ** 104;
    var females = [_]f64{100_000.0} ** 104;
    const total_demand = AgricultureEngine.calculateTotalFoodDemand(&males, &females, &curves);
    try std.testing.expect(total_demand > 0.0);

    // Performance latency benchmark hot loop (100,000 iterations)
    var engine = AgricultureEngine.init();
    const runs: usize = 100_000;

    // Benchmark 1: Agriculture step() alone (ODEs, table lookups, guardrails)
    var timer_step = try std.time.Timer.start();
    var dummy_step: f64 = 0.0;
    for (0..runs) |_| {
        const out = engine.step(7.0e9, 25.0e12, 3500.0, 1.2, 1.6e12, 1.0);
        dummy_step += out.food_produced;
    }
    const elapsed_step_ns = timer_step.read();
    const ns_per_step = @as(f64, @floatFromInt(elapsed_step_ns)) / @as(f64, @floatFromInt(runs));

    // Benchmark 2: Combined step() + 104-element vector calculateMortalityMultiplier()
    var timer_combined = try std.time.Timer.start();
    var dummy_comb: f64 = 0.0;
    for (0..runs) |_| {
        const out = engine.step(7.0e9, 25.0e12, 3500.0, 1.2, 1.6e12, 1.0);
        const mort = AgricultureEngine.calculateMortalityMultiplier(out.food_ratio, &curves.starvation_vulnerability);
        dummy_comb += out.food_produced + mort[0];
    }
    const elapsed_comb_ns = timer_combined.read();
    const ns_per_comb = @as(f64, @floatFromInt(elapsed_comb_ns)) / @as(f64, @floatFromInt(runs));

    std.debug.print("\n[Benchmark Latency] Agriculture step() alone: {d:.2} ns/step\n", .{ns_per_step});
    std.debug.print("[Benchmark Latency] Combined step() + 104-cohort mortality vector: {d:.2} ns/step\n", .{ns_per_comb});

    const builtin = @import("builtin");
    if (builtin.mode != .Debug) {
        try std.testing.expect(ns_per_step < 50.0); // Strict sub-50ns step latency requirement in Release builds!
    }
    try std.testing.expect(ns_per_step > 0.0);
    try std.testing.expect(ns_per_comb > 0.0);
    try std.testing.expect(dummy_step > 0.0 and dummy_comb > 0.0);
}
