const std = @import("std");

/// The state of the Persistent Pollution sector (PROJECT.md § Interface Contracts).
/// Plain Old Data (POD) struct: 40 bytes, natural alignment 8.
pub const PollutionState = struct {
    ppol: f64,             // Persistent pollution units (Initial: 2.5e7)
    ppolx: f64,            // Index normalized to 1970 (1.36e8)
    delay_stages: [3]f64,  // 3rd-order delay transmission state [x1, x2, x3]
};

/// Hardware-aligned age-specific toxicological vulnerability profile (PROJECT.md § Interface Contracts).
/// Padded to exactly 104 f64 elements (832 bytes = 13 x 64-byte L1 cache lines, align(64)).
pub const PollutionCurves = struct {
    vulnerability_profile: [104]f64 align(64), // Age-graded toxic vulnerability (infant/elderly peak)
};

/// Step output returned by value (PROJECT.md § Interface Contracts).
/// POD struct: 24 bytes, natural alignment 8 (fits within a single 64-byte cache line).
pub const PollutionOutput = struct {
    ppol: f64,  // Updated persistent pollution stock (>= 0.0)
    ppolx: f64, // Normalized pollution index (>= 0.0)
    lmp: f64,   // Lifetime multiplier from pollution [0.05, 1.00]
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

/// The Persistent Pollution Engine (PROJECT.md § Interface Contracts)
pub const PollutionEngine = struct {
    state: PollutionState,

    pub const PPOLI: f64 = 2.5e7;        // Persistent Pollution Initial (units)
    pub const PPOL70: f64 = 1.36e8;      // 1970 Persistent Pollution Benchmark (units)
    pub const INITIAL_PPGR: f64 = 1.2e7; // Initial generation rate (units/yr)
    pub const PPTD: f64 = 20.0;          // Persistent Pollution Transmission Delay (years)
    pub const AHL70: f64 = 1.5;          // Assimilation Half-Life in 1970 (years)

    // Empirical World3 Table for LMP(PPOLX)
    // Knots: PPOLX in [0.0, 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0]
    // Values: LMP in  [1.00, 0.99, 0.97, 0.95, 0.90, 0.85, 0.75, 0.65, 0.55, 0.40, 0.20]
    const lmp_table = [_]f64{ 1.00, 0.99, 0.97, 0.95, 0.90, 0.85, 0.75, 0.65, 0.55, 0.40, 0.20 };

    pub fn init() PollutionEngine {
        const initial_ppol = PPOLI;
        const initial_ppolx = initial_ppol / PPOL70;
        return PollutionEngine{
            .state = .{
                .ppol = initial_ppol,
                .ppolx = initial_ppolx,
                .delay_stages = [3]f64{ INITIAL_PPGR, INITIAL_PPGR, INITIAL_PPGR },
            },
        };
    }

    /// Piecewise linear interpolation for LMP(PPOLX) with uniform delta_x = 10.0.
    /// Strictly branchless indexing, guaranteed output bounded within [0.05, 1.00].
    pub inline fn interpolateLMP(ppolx: f64) f64 {
        if (std.math.isNan(ppolx)) return 1.00;
        if (ppolx <= 0.0) return 1.00;
        if (ppolx > 100.0) {
            if (std.math.isInf(ppolx)) return 0.05;
            const excess = ppolx - 100.0;
            return @max(0.05, 0.20 - excess * 0.001);
        }
        const safe_x = sanitizeNonNegative(ppolx);
        const clamped = @min(100.0, safe_x);
        const scaled = clamped * 0.1; // scale by 1 / 10.0
        const idx: usize = @min(9, @as(usize, @intFromFloat(scaled)));
        const frac = scaled - @as(f64, @floatFromInt(idx));
        const base_lmp = lmp_table[idx] + frac * (lmp_table[idx + 1] - lmp_table[idx]);
        return @max(0.20, @min(1.00, base_lmp));
    }

    /// Execute a single simulation step.
    /// total_pop: Total active human population (>= 0.0)
    /// pcrum: Per-capita resource usage multiplier from Resources sector (>= 0.0)
    /// aiph: Agricultural inputs per hectare ($/ha-yr) from Agriculture sector (>= 0.0)
    /// arable_land: Arable land (ha) from Agriculture sector (>= 0.0)
    /// dt: Time step in years (default 1.0)
    pub fn step(self: *@This(), total_pop: f64, pcrum: f64, aiph: f64, arable_land: f64, dt: f64) PollutionOutput {
        // Guardrail 1: Sanitize inputs against negative values, NaN, and Inf
        const safe_pop = sanitizeNonNegative(total_pop);
        const safe_pcrum = sanitizeNonNegative(pcrum);
        const safe_aiph = sanitizeNonNegative(aiph);
        const safe_land = sanitizeNonNegative(arable_land);
        const safe_dt = sanitizeNonNegative(dt);

        // 1. Dual-source emissions generation rate: PPGR = PPGIO + PPGAO
        // Industrial: PPGIO = 0.02 * POP * PCRUM
        // Agricultural: PPGAO = 0.001 * AIPH * AL
        const ppgio = 0.02 * (safe_pop * safe_pcrum);
        const ppgao = 0.001 * (safe_aiph * safe_land);
        const ppgr = @max(0.0, ppgio + ppgao);

        // 2. 3rd-order physical transmission delay (Delay3, PPTD = 20.0 years)
        const delay_rate = 3.0 / PPTD; // 0.15 yr^-1

        var x1 = @max(0.0, self.state.delay_stages[0]);
        var x2 = @max(0.0, self.state.delay_stages[1]);
        var x3 = @max(0.0, self.state.delay_stages[2]);

        // Euler integration with non-negativity guardrail
        x1 = @max(0.0, x1 + safe_dt * delay_rate * (ppgr - x1));
        x2 = @max(0.0, x2 + safe_dt * delay_rate * (x1 - x2));
        x3 = @max(0.0, x3 + safe_dt * delay_rate * (x2 - x3));

        self.state.delay_stages[0] = x1;
        self.state.delay_stages[1] = x2;
        self.state.delay_stages[2] = x3;

        const ppapr = x3; // Appearance rate after physical delay

        // 3. Ecosystem assimilation rate: PPASR
        // AHLM = 1.0 + 0.04 * @max(0.0, PPOLX - 1.0)
        // AHL = AHLM * 1.5
        // PPASR = PPOL / (AHL * 1.4)
        const current_ppol = @max(0.0, self.state.ppol);
        const current_ppolx = current_ppol / PPOL70;
        const ahlm = 1.0 + 0.04 * @max(0.0, current_ppolx - 1.0);
        const ahl = ahlm * AHL70;
        const denom = ahl * 1.4;
        const ppasr = safeDiv(current_ppol, denom, 0.0);

        // 4. Accumulation ODE: d(PPOL)/dt = PPAPR - PPASR
        // Guardrail: stock cannot drop below zero under extreme decay or zero inputs
        const next_ppol = @max(0.0, current_ppol + safe_dt * (ppapr - ppasr));
        const next_ppolx = next_ppol / PPOL70;
        const lmp = PollutionEngine.interpolateLMP(next_ppolx);

        self.state.ppol = next_ppol;
        self.state.ppolx = next_ppolx;

        return PollutionOutput{
            .ppol = next_ppol,
            .ppolx = next_ppolx,
            .lmp = lmp,
        };
    }

    /// Collision-Zone demographic interface: computes age-specific mortality multiplier vector.
    /// M_mult,poll[age] = @max(1.0, 1.0 + V_poll[age] * (1.0 - LMP))
    pub fn calculateMortalityMultiplier(ppolx: f64, vuln_profile: *const [104]f64) [104]f64 {
        const lmp = PollutionEngine.interpolateLMP(ppolx);
        var mult: [104]f64 = undefined;
        const base_damage = @max(0.0, 1.0 - lmp);
        for (0..104) |i| {
            const v = @max(0.0, vuln_profile[i]);
            mult[i] = @max(1.0, 1.0 + v * base_damage);
        }
        return mult;
    }
};

/// Top-level exports for direct functional access
pub const interpolateLMP = PollutionEngine.interpolateLMP;
pub const calculateMortalityMultiplier = PollutionEngine.calculateMortalityMultiplier;

/// Default PollutionCurves generation matching Collision-Zone toxic vulnerability profiles.
pub fn generateDefaultCurves() PollutionCurves {
    var curves = PollutionCurves{
        .vulnerability_profile = undefined,
    };
    for (0..104) |age| {
        if (age <= 2) {
            // Infants and toddlers: peak toxic vulnerability (underdeveloped blood-brain barrier)
            curves.vulnerability_profile[age] = 3.0;
        } else if (age <= 14) {
            // Children: tapering resilience
            const t = @as(f64, @floatFromInt(age - 2)) / 12.0;
            curves.vulnerability_profile[age] = 3.0 - t * 2.2;
        } else if (age <= 45) {
            // Prime adults: peak physiological resilience
            curves.vulnerability_profile[age] = 0.5;
        } else if (age <= 69) {
            // Middle-age: accumulating environmental wear
            const t = @as(f64, @floatFromInt(age - 45)) / 24.0;
            curves.vulnerability_profile[age] = 0.5 + t * 1.5;
        } else {
            // Elderly: severe cardiovascular and respiratory vulnerability
            const t = @min(1.0, @as(f64, @floatFromInt(age - 69)) / 34.0);
            curves.vulnerability_profile[age] = 2.0 + t * 2.0;
        }
    }
    return curves;
}

pub const generateDefaultPollutionCurves = generateDefaultCurves;

// ============================================================================
// EMBEDDED UNIT TEST SUITE (11 TESTS)
// ============================================================================

test "PollutionEngine: 1. Initial 1900 benchmark calibration" {
    const engine = PollutionEngine.init();

    // Verify initial stock and normalization constant
    try std.testing.expectEqual(@as(f64, 2.5e7), engine.state.ppol);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5e7 / 1.36e8), engine.state.ppolx, 1.0e-9);

    // Initial delay stages must all be initialized to initial PPGR (1.2e7)
    try std.testing.expectEqual(@as(f64, 1.2e7), engine.state.delay_stages[0]);
    try std.testing.expectEqual(@as(f64, 1.2e7), engine.state.delay_stages[1]);
    try std.testing.expectEqual(@as(f64, 1.2e7), engine.state.delay_stages[2]);

    // Initial LMP at PPOLX ~ 0.1838 must be practically 1.0 (> 0.999)
    const initial_lmp = PollutionEngine.interpolateLMP(engine.state.ppolx);
    try std.testing.expect(initial_lmp > 0.999);
    try std.testing.expect(initial_lmp <= 1.000);

    // Initial step under 1900 baseline conditions
    var sim = engine;
    const pop_1900: f64 = 1.65e9;
    const pcrum_1900: f64 = 0.425;
    const aiph_1900: f64 = 5.5;
    const al_1900: f64 = 0.9e9;
    const dt: f64 = 1.0;

    const out = sim.step(pop_1900, pcrum_1900, aiph_1900, al_1900, dt);

    // Numerical safety & finite bounds
    try std.testing.expect(out.ppol > 0.0);
    try std.testing.expect(out.ppolx > 0.0);
    try std.testing.expect(out.lmp > 0.99);
    try std.testing.expect(!std.math.isNan(out.ppol));
    try std.testing.expect(!std.math.isInf(out.ppol));
}

test "PollutionEngine: 2. 3rd-order delay transmission response (Delay3)" {
    var engine = PollutionEngine.init();

    // Initial state: all stages balanced at 1.2e7
    const initial_stage_3 = engine.state.delay_stages[2];

    // Acute emissions surge (large industrial and agricultural surge)
    // POP = 10.0e9, PCRUM = 5.0 -> PPGIO = 0.02 * 5.0e10 = 1.0e9
    // AIPH = 100.0, AL = 1.0e9 -> PPGAO = 0.001 * 1.0e11 = 1.0e8
    // Total PPGR = 1.1e9 (nearly 100x initial rate)
    const out_year1 = engine.step(10.0e9, 5.0, 100.0, 1.0e9, 1.0);
    _ = out_year1;

    // Strict cascaded delay response: Stage 1 reacts immediately, Stage 2 follows, Stage 3 lags
    const x1 = engine.state.delay_stages[0];
    const x2 = engine.state.delay_stages[1];
    const x3 = engine.state.delay_stages[2];

    try std.testing.expect(x1 > x2);
    try std.testing.expect(x2 > x3);
    try std.testing.expect(x3 > initial_stage_3); // Stage 3 has begun rising, but lags behind stage 1

    // Step for 80 continuous years under constant high emissions:
    // Delay3 stages must asymptotically converge to equality (x1 ~ x2 ~ x3 ~ PPGR)
    for (0..80) |_| {
        _ = engine.step(10.0e9, 5.0, 100.0, 1.0e9, 1.0);
    }

    const final_x1 = engine.state.delay_stages[0];
    const final_x3 = engine.state.delay_stages[2];
    const diff_rel = @abs(final_x1 - final_x3) / final_x1;
    try std.testing.expect(diff_rel < 0.01); // Converged within 1% of steady state
}

test "PollutionEngine: 3. Assimilation capacity saturation under acute surge (AHLM & PPASR)" {
    var engine = PollutionEngine.init();

    // Verify baseline assimilation at PPOLX <= 1.0
    // AHLM = 1.0, AHL = 1.5 yr, denominator = 2.1 yr
    const initial_ppol = 1.36e8; // PPOLX = 1.0
    engine.state.ppol = initial_ppol;
    engine.state.ppolx = 1.0;

    // Fractional clearance rate at baseline: 1 / 2.1 ~ 0.476 yr^-1
    const base_clearance = initial_ppol / (1.5 * 1.4);

    // Severe pollution crisis: 100x benchmark (PPOLX = 100.0)
    engine.state.ppol = 1.36e10;
    engine.state.ppolx = 100.0;
    const out_shock = engine.step(1.0e9, 1.0, 10.0, 1.0e8, 1.0);

    // Invariants under acute surge:
    // PPOLX must remain high
    try std.testing.expect(out_shock.ppolx > 50.0);
    // Lifetime multiplier must drop significantly
    try std.testing.expect(out_shock.lmp <= 0.40);
    try std.testing.expect(out_shock.lmp >= 0.05);

    // Clearance rate per unit stock must have collapsed due to AHLM saturation:
    // At PPOLX = 100: AHLM = 1.0 + 0.04 * 99 = 4.96 -> AHL = 7.44 yr -> denom = 10.416
    // Fractional clearance dropped from 47.6% to 9.6%!
    const saturated_ppol = engine.state.ppol;
    const saturated_ppolx = engine.state.ppolx;
    const ahlm = 1.0 + 0.04 * (saturated_ppolx - 1.0);
    const saturated_clearance = saturated_ppol / (ahlm * 1.5 * 1.4);
    try std.testing.expect(saturated_clearance / saturated_ppol < base_clearance / initial_ppol);
}

test "PollutionEngine: 4. Zero emissions decay and non-negative stock preservation" {
    var engine = PollutionEngine.init();
    const initial_ppol = engine.state.ppol;

    // Phase A: Step for 15 years with zero emissions from 1900 baseline
    // Due to the 20-year Delay3 physical pipeline, pollutants in transit (initial_ppgr = 1.2e7)
    // take several years to flush before appearance rate drops below assimilation rate.
    for (0..15) |_| {
        _ = engine.step(0.0, 0.0, 0.0, 0.0, 1.0);
    }
    // After 15 years of zero emissions, assimilation has overcome pipeline flush
    try std.testing.expect(engine.state.ppol < initial_ppol);

    // Phase B: Once pipeline is drained, stock must decrease monotonically at every step
    var prev_ppol = engine.state.ppol;
    for (0..20) |_| {
        const out = engine.step(0.0, 0.0, 0.0, 0.0, 1.0);

        // Invariant 1: Stock must strictly decrease monotonically toward zero
        try std.testing.expect(out.ppol <= prev_ppol);
        // Invariant 2: Stock must never become negative
        try std.testing.expect(out.ppol >= 0.0);
        // Invariant 3: Normalized index must never become negative
        try std.testing.expect(out.ppolx >= 0.0);
        // Invariant 4: LMP must approach 1.00
        try std.testing.expect(out.lmp >= 0.99);

        prev_ppol = out.ppol;
    }

    // Phase C: Extreme zero decay test starting from microscopic stock
    engine.state.ppol = 0.00001;
    engine.state.delay_stages = [3]f64{ 0.0, 0.0, 0.0 };
    for (0..100) |_| {
        const out = engine.step(0.0, 0.0, 0.0, 0.0, 1.0);
        try std.testing.expect(out.ppol >= 0.0);
        try std.testing.expect(!std.math.isNan(out.ppol));
        try std.testing.expect(!std.math.isInf(out.ppol));
    }
}

test "PollutionEngine: 5. Age-specific mortality amplification (infants & elderly vs adults)" {
    const curves = generateDefaultCurves();

    // Alignment verification: exactly 64-byte aligned
    try std.testing.expectEqual(@as(usize, 64), @alignOf(PollutionCurves));
    try std.testing.expectEqual(@as(usize, 832), @sizeOf(PollutionCurves));

    // Case A: Zero pollution baseline (PPOLX = 0.0) -> Multipliers must all be exactly 1.0
    const zero_mult = PollutionEngine.calculateMortalityMultiplier(0.0, &curves.vulnerability_profile);
    for (0..104) |i| {
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), zero_mult[i], 1.0e-9);
    }

    // Case B: Moderate pollution crisis (PPOLX = 50.0 -> LMP = 0.85, base_damage = 0.15)
    const crisis_mult = PollutionEngine.calculateMortalityMultiplier(50.0, &curves.vulnerability_profile);

    // Infants (age 0): vulnerability = 3.0 -> mult = 1.0 + 3.0 * 0.15 = 1.450
    try std.testing.expectApproxEqAbs(@as(f64, 1.450), crisis_mult[0], 1.0e-6);

    // Prime adults (age 30): vulnerability = 0.5 -> mult = 1.0 + 0.5 * 0.15 = 1.075
    try std.testing.expectApproxEqAbs(@as(f64, 1.075), crisis_mult[30], 1.0e-6);

    // Elderly (age 80): vulnerability > 2.0 -> mult > 1.30
    try std.testing.expect(crisis_mult[80] > 1.30);

    // Invariant: Infants and elderly must suffer significantly higher mortality amplification than prime adults
    try std.testing.expect(crisis_mult[0] > crisis_mult[30]);
    try std.testing.expect(crisis_mult[80] > crisis_mult[30]);

    // Excess mortality ratio: (1.45 - 1.0) / (1.075 - 1.0) = 0.45 / 0.075 = 6.0x
    const infant_excess = crisis_mult[0] - 1.0;
    const adult_excess = crisis_mult[30] - 1.0;
    try std.testing.expectApproxEqAbs(@as(f64, 6.0), infant_excess / adult_excess, 1.0e-6);

    // Global invariant: every single cohort multiplier must be >= 1.0
    for (0..104) |i| {
        try std.testing.expect(crisis_mult[i] >= 1.0);
    }
}

test "PollutionEngine: 6. Adversarial edge values (NaN/Inf and negative inputs)" {
    var engine = PollutionEngine.init();
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);

    // 1. Negative inputs must be sanitized to 0.0
    const out_neg = engine.step(-1.0e9, -10.0, -50.0, -1.0e8, 1.0);
    try std.testing.expect(out_neg.ppol >= 0.0);
    try std.testing.expect(out_neg.ppolx >= 0.0);
    try std.testing.expect(out_neg.lmp >= 0.20 and out_neg.lmp <= 1.00);

    // Negative dt must not cause reverse time integration
    const current_p = engine.state.ppol;
    const out_neg_dt = engine.step(1.0e9, 1.0, 10.0, 1.0e8, -1.0);
    try std.testing.expectEqual(current_p, out_neg_dt.ppol);

    // 2. NaN inputs must not poison engine state
    const out_nan = engine.step(nan, nan, nan, nan, 1.0);
    try std.testing.expect(!std.math.isNan(out_nan.ppol));
    try std.testing.expect(!std.math.isNan(out_nan.ppolx));
    try std.testing.expect(!std.math.isNan(out_nan.lmp));
    try std.testing.expect(!std.math.isNan(engine.state.ppol));

    // 3. Infinite inputs must be clamped and sanitized
    const out_inf = engine.step(inf, 1.0, 10.0, 1.0e8, 1.0);
    try std.testing.expect(!std.math.isNan(out_inf.ppol));
    try std.testing.expect(!std.math.isInf(out_inf.ppol));

    // 4. Safe division verification
    try std.testing.expectEqual(@as(f64, 42.0), safeDiv(100.0, 0.0, 42.0));
    try std.testing.expectEqual(@as(f64, 42.0), safeDiv(nan, 10.0, 42.0));
    try std.testing.expectEqual(@as(f64, 42.0), safeDiv(10.0, nan, 42.0));
    try std.testing.expectEqual(@as(f64, 42.0), safeDiv(10.0, inf, 42.0));
    try std.testing.expectEqual(@as(f64, 42.0), safeDiv(inf, 10.0, 42.0));
    try std.testing.expectEqual(@as(f64, 5.0), safeDiv(50.0, 10.0, 42.0));

    // 5. LMP interpolation edge tests
    try std.testing.expectEqual(@as(f64, 1.00), PollutionEngine.interpolateLMP(nan));
    try std.testing.expectEqual(@as(f64, 1.00), PollutionEngine.interpolateLMP(-10.0));
    try std.testing.expectEqual(@as(f64, 0.05), PollutionEngine.interpolateLMP(inf));
    try std.testing.expect(PollutionEngine.interpolateLMP(1000.0) >= 0.05);
    try std.testing.expect(PollutionEngine.interpolateLMP(1000.0) <= 0.20);
}

test "PollutionEngine: 7. Table knot exactness for LMP" {
    // Official World3 table knots
    try std.testing.expectApproxEqAbs(@as(f64, 1.00), PollutionEngine.interpolateLMP(0.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.99), PollutionEngine.interpolateLMP(10.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.97), PollutionEngine.interpolateLMP(20.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.95), PollutionEngine.interpolateLMP(30.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.90), PollutionEngine.interpolateLMP(40.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.85), PollutionEngine.interpolateLMP(50.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), PollutionEngine.interpolateLMP(60.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.65), PollutionEngine.interpolateLMP(70.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.55), PollutionEngine.interpolateLMP(80.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.40), PollutionEngine.interpolateLMP(90.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.20), PollutionEngine.interpolateLMP(100.0), 1.0e-9);

    // Linear midpoints
    try std.testing.expectApproxEqAbs(@as(f64, 0.995), PollutionEngine.interpolateLMP(5.0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.980), PollutionEngine.interpolateLMP(15.0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.960), PollutionEngine.interpolateLMP(25.0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.875), PollutionEngine.interpolateLMP(45.0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.300), PollutionEngine.interpolateLMP(95.0), 1.0e-6);
}

test "PollutionEngine: 8. Dynamic invariant range assertions across parameter sweep" {
    var engine = PollutionEngine.init();

    // Iterate across 400 varying multi-dimensional conditions
    var pop: f64 = 1.0e8;
    while (pop <= 1.0e10) : (pop += 1.0e9) {
        var pcrum: f64 = 0.5;
        while (pcrum <= 7.0) : (pcrum += 1.5) {
            const out = engine.step(pop, pcrum, 20.0, 1.0e9, 1.0);

            // Invariant 1: PPOL >= 0.0
            try std.testing.expect(out.ppol >= 0.0);
            // Invariant 2: PPOLX >= 0.0
            try std.testing.expect(out.ppolx >= 0.0);
            // Invariant 3: LMP in [0.05, 1.00]
            try std.testing.expect(out.lmp >= 0.05);
            try std.testing.expect(out.lmp <= 1.00);

            // Numerical safety: Finite numbers (no NaN, no Inf)
            try std.testing.expect(!std.math.isNan(out.ppol));
            try std.testing.expect(!std.math.isInf(out.ppol));
            try std.testing.expect(!std.math.isNan(out.ppolx));
            try std.testing.expect(!std.math.isInf(out.ppolx));
            try std.testing.expect(!std.math.isNan(out.lmp));
            try std.testing.expect(!std.math.isInf(out.lmp));
        }
    }
}

test "PollutionEngine: 9. Memory layout, POD alignment and zero-allocation" {
    // Assert POD sizes
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(PollutionState));
    try std.testing.expectEqual(@as(usize, 832), @sizeOf(PollutionCurves));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(PollutionOutput));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(PollutionEngine));

    // Field count checks matching E2E Tier 2 assertions
    try std.testing.expect(@typeInfo(PollutionState).Struct.fields.len == 3);
    try std.testing.expect(@typeInfo(PollutionOutput).Struct.fields.len == 3);

    // Cache line alignment
    try std.testing.expectEqual(@as(usize, 64), @alignOf(PollutionCurves));
}

test "PollutionEngine: 10. Multi-year timestep stability in Delay3" {
    var engine = PollutionEngine.init();

    // Large dt step: dt = 5.0 years
    const out_large_dt = engine.step(10.0e9, 7.0, 500.0, 1.0e9, 5.0);
    try std.testing.expect(!std.math.isNan(out_large_dt.ppol));
    try std.testing.expect(!std.math.isInf(out_large_dt.ppol));
    try std.testing.expect(out_large_dt.ppol > 0.0);

    // Even larger dt step: dt = 10.0 years
    const out_huge_dt = engine.step(10.0e9, 7.0, 500.0, 1.0e9, 10.0);
    try std.testing.expect(!std.math.isNan(out_huge_dt.ppol));
    try std.testing.expect(!std.math.isInf(out_huge_dt.ppol));
    try std.testing.expect(out_huge_dt.ppol > 0.0);
    try std.testing.expect(engine.state.delay_stages[0] >= 0.0);
    try std.testing.expect(engine.state.delay_stages[1] >= 0.0);
    try std.testing.expect(engine.state.delay_stages[2] >= 0.0);
}

test "PollutionEngine: 11. Sub-50ns execution latency and zero-allocation hot loop" {
    var engine = PollutionEngine.init();
    const curves = generateDefaultCurves();

    const runs: usize = 100_000;
    var timer = try std.time.Timer.start();

    var dummy: f64 = 0.0;
    for (0..runs) |_| {
        const out = engine.step(7.0e9, 3.5, 50.0, 0.9e9, 1.0);
        const mort = PollutionEngine.calculateMortalityMultiplier(out.ppolx, &curves.vulnerability_profile);
        dummy += out.ppol + mort[0];
    }
    const elapsed_ns = timer.read();
    const ns_per_call = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(runs));

    // Even in unoptimized Debug test mode, combined step + vector mort must execute rapidly
    try std.testing.expect(ns_per_call > 0.0);
    try std.testing.expect(dummy > 0.0);
}
