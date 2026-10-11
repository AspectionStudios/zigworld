const std = @import("std");

/// The state of the Non-Renewable Resources sector (PROJECT.md § Interface Contracts).
/// Plain Old Data (POD) struct: 16 bytes, natural alignment 8.
pub const ResourceState = struct {
    remaining_resources: f64, // Initial: 1.0e12 (NRI)
    fcaor: f64,               // Fraction of capital allocated to resources [0.05, 1.00]
};

/// Hardware-aligned age-specific resource consumption profile (PROJECT.md § Interface Contracts).
/// Padded to exactly 104 f64 elements (832 bytes = 13 x 64-byte L1 cache lines, align(64)).
pub const ResourceCurves = struct {
    resource_usage_profile: [104]f64 align(64), // Per-capita usage profile by age
};

/// Step output returned by value (PROJECT.md § Interface Contracts).
/// POD struct: 40 bytes, natural alignment 8 (fits within a single 64-byte cache line).
pub const ResourceOutput = struct {
    remaining_resources: f64, // Updated resource stock (>= 0.0)
    nrfr: f64,                // Resource fraction remaining [0.0, 1.0]
    fcaor: f64,               // Fraction of capital allocated to resources [0.05, 1.00]
    resource_usage_rate: f64, // Actual resource usage rate (NRUR >= 0.0)
    pcrum: f64,               // Per-capita resource usage multiplier [0.0, 7.0]
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

/// The Non-Renewable Resources Engine (PROJECT.md § Interface Contracts)
pub const ResourceEngine = struct {
    state: ResourceState,

    pub const NRI: f64 = 1.0e12; // Non-Renewable Resources Initial (resource units)
    pub const NRUF: f64 = 1.0;  // Non-Renewable Resource Usage Factor (baseline = 1.0)

    // World3 Empirical Table for PCRUM(IOPC)
    // Knots: IOPC in [0, 200, 400, 600, 800, 1000, 1200, 1400, 1600]
    // Uniform knot spacing: delta_x = 200.0
    const pcrum_table = [_]f64{ 0.0, 0.85, 2.60, 4.40, 5.40, 6.20, 6.80, 7.00, 7.00 };

    // World3 Empirical Table for FCAOR(NRFR)
    // Knots: NRFR in [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
    // Uniform knot spacing: delta_x = 0.1
    const fcaor_table = [_]f64{ 1.00, 0.90, 0.70, 0.50, 0.20, 0.10, 0.05, 0.05, 0.05, 0.05, 0.05 };

    pub fn init() ResourceEngine {
        return ResourceEngine{
            .state = .{
                .remaining_resources = NRI,
                .fcaor = 0.05,
            },
        };
    }

    /// Piecewise linear interpolation for PCRUM(IOPC) with uniform delta_x = 200.0.
    /// Strictly branchless indexing, guaranteed output in [0.0, 7.0].
    pub inline fn interpolatePCRUM(iopc: f64) f64 {
        const sanitized = sanitizeNonNegative(iopc);
        const clamped_iopc = @min(1600.0, sanitized);
        const scaled = clamped_iopc * (1.0 / 200.0);
        const idx: usize = @min(7, @as(usize, @intFromFloat(scaled)));
        const frac = scaled - @as(f64, @floatFromInt(idx));
        const raw_pcrum = pcrum_table[idx] + frac * (pcrum_table[idx + 1] - pcrum_table[idx]);
        return @max(0.0, @min(7.0, raw_pcrum));
    }

    /// Piecewise linear interpolation for FCAOR(NRFR) with uniform delta_x = 0.1.
    /// Strictly branchless indexing, guaranteed output in [0.05, 1.00].
    pub inline fn interpolateFCAOR(nrfr: f64) f64 {
        const sanitized = sanitizeNonNegative(nrfr);
        const clamped_nrfr = @min(1.0, sanitized);
        const scaled = clamped_nrfr * 10.0;
        const idx: usize = @min(9, @as(usize, @intFromFloat(scaled)));
        const frac = scaled - @as(f64, @floatFromInt(idx));
        const raw_fcaor = fcaor_table[idx] + frac * (fcaor_table[idx + 1] - fcaor_table[idx]);
        return @max(0.05, @min(1.00, raw_fcaor));
    }

    /// Execute a single simulation step.
    /// total_pop: Total active human population (or effective resource-consuming population)
    /// iopc: Industrial Output Per Capita ($/person-year)
    /// dt: Time step in years (default 1.0)
    pub fn step(self: *@This(), total_pop: f64, iopc: f64, dt: f64) ResourceOutput {
        // Guardrail: Sanitize inputs against negative values, NaN, and Inf
        const safe_pop = sanitizeNonNegative(total_pop);
        const safe_iopc = sanitizeNonNegative(iopc);
        const safe_dt = sanitizeNonNegative(dt);

        // Current physical stock before depletion (clamped >= 0.0)
        const current_nr = @max(0.0, self.state.remaining_resources);

        // 1. Lookup PCRUM from IOPC via branchless table interpolation [0.0, 7.0]
        const pcrum = ResourceEngine.interpolatePCRUM(safe_iopc);

        // 2. Calculate Resource Usage Rate: NRUR = POP * PCRUM * NRUF (>= 0.0)
        const nrur = @max(0.0, safe_pop * pcrum * NRUF);

        // 3. Depletion ODE: d(NR)/dt = -NRUR
        // Guardrail: Physical stock cannot drop below zero; actual depletion bounded by available stock
        const total_demand = nrur * safe_dt;
        const actual_depletion = @min(current_nr, total_demand);
        const next_nr = @max(0.0, current_nr - actual_depletion);
        self.state.remaining_resources = next_nr;

        // 4. Calculate NRFR (Resource Fraction Remaining) from updated stock clamped to [0.0, 1.0]
        const nrfr = @max(0.0, @min(1.0, next_nr * (1.0 / NRI)));

        // 5. Lookup FCAOR from NRFR via branchless table interpolation [0.05, 1.00]
        const fcaor = ResourceEngine.interpolateFCAOR(nrfr);
        self.state.fcaor = fcaor;

        return ResourceOutput{
            .remaining_resources = next_nr,
            .nrfr = nrfr,
            .fcaor = fcaor,
            .resource_usage_rate = nrur,
            .pcrum = pcrum,
        };
    }

    /// Collision-Zone vector aggregation: computes age-weighted effective population.
    pub fn calculateEffectivePopulation(
        males: *const [104]f64,
        females: *const [104]f64,
        curves: *const ResourceCurves,
    ) f64 {
        var eff_pop: f64 = 0.0;
        for (0..104) |i| {
            eff_pop += (males[i] + females[i]) * curves.resource_usage_profile[i];
        }
        return @max(0.0, eff_pop);
    }
};

/// Top-level exports for direct functional access
pub const interpolatePCRUM = ResourceEngine.interpolatePCRUM;
pub const interpolateFCAOR = ResourceEngine.interpolateFCAOR;
pub const calculateEffectivePopulation = ResourceEngine.calculateEffectivePopulation;

/// Default ResourceCurves generation matching Collision-Zone life-cycle profiles.
pub fn generateDefaultCurves() ResourceCurves {
    var curves = ResourceCurves{
        .resource_usage_profile = undefined,
    };
    for (0..104) |age| {
        const a: f64 = @floatFromInt(age);
        if (age < 5) {
            // Infants & toddlers
            curves.resource_usage_profile[age] = 0.15;
        } else if (age < 18) {
            // Children & teenagers scaling from 0.20 to 0.85
            curves.resource_usage_profile[age] = 0.20 + (a - 5.0) * (0.65 / 13.0);
        } else if (age <= 65) {
            // Peak adult consumption
            curves.resource_usage_profile[age] = 1.00;
        } else {
            // Elderly: tapering down to 0.50
            const drop = (a - 65.0) / 38.0;
            curves.resource_usage_profile[age] = @max(0.50, 1.00 - drop * 0.50);
        }
    }
    return curves;
}

// ============================================================================
// EMBEDDED UNIT TEST SUITE (11 TESTS)
// ============================================================================

test "ResourceEngine: initialization state and invariants" {
    const engine = ResourceEngine.init();
    try std.testing.expectEqual(@as(f64, 1.0e12), engine.state.remaining_resources);
    try std.testing.expectEqual(@as(f64, 0.05), engine.state.fcaor);

    // Initial fraction remaining must be exactly 1.0
    const nrfr = engine.state.remaining_resources / ResourceEngine.NRI;
    try std.testing.expectEqual(@as(f64, 1.0), nrfr);
}

test "ResourceEngine: standard year step depletion" {
    var engine = ResourceEngine.init();
    const pop: f64 = 1.65e9; // 1900 population
    const iopc: f64 = 100.0; // Midway between 0 and 200 -> PCRUM = 0.425
    const dt: f64 = 1.0;

    const out = engine.step(pop, iopc, dt);

    // PCRUM at IOPC=100: midpoint between 0.0 and 0.85 = 0.425
    try std.testing.expectApproxEqAbs(@as(f64, 0.425), out.pcrum, 1.0e-6);

    // Usage rate: 1.65e9 * 0.425 = 7.0125e8
    const expected_usage: f64 = 1.65e9 * 0.425;
    try std.testing.expectApproxEqAbs(expected_usage, out.resource_usage_rate, 1.0e-3);

    // Remaining resources: 1.0e12 - 7.0125e8 = 9.9929875e11
    const expected_remaining = 1.0e12 - expected_usage;
    try std.testing.expectApproxEqAbs(expected_remaining, out.remaining_resources, 1.0e-3);
    try std.testing.expectApproxEqAbs(expected_remaining, engine.state.remaining_resources, 1.0e-3);

    // NRFR and FCAOR checks
    try std.testing.expect(out.nrfr > 0.99);
    try std.testing.expectEqual(@as(f64, 0.05), out.fcaor);
}

test "ResourceEngine: complete resource exhaustion (NR -> 0, FCAOR -> 1.0)" {
    var engine = ResourceEngine.init();
    // Artificially reduce stock near exhaustion
    engine.state.remaining_resources = 1.0e8;

    // Apply massive annual demand that vastly exceeds available stock
    const pop: f64 = 8.0e9;
    const iopc: f64 = 1600.0; // PCRUM = 7.0 -> demand = 5.6e10 >> 1.0e8
    const dt: f64 = 1.0;

    const out = engine.step(pop, iopc, dt);

    // Stock must clamp cleanly to exactly 0.0, never negative
    try std.testing.expectEqual(@as(f64, 0.0), out.remaining_resources);
    try std.testing.expectEqual(@as(f64, 0.0), engine.state.remaining_resources);
    try std.testing.expectEqual(@as(f64, 0.0), out.nrfr);
    try std.testing.expectEqual(@as(f64, 1.00), out.fcaor);

    // Step again while depleted: stock must remain 0.0, no NaN, no Inf, no underflow
    const out2 = engine.step(pop, iopc, dt);
    try std.testing.expectEqual(@as(f64, 0.0), out2.remaining_resources);
    try std.testing.expectEqual(@as(f64, 0.0), out2.nrfr);
    try std.testing.expectEqual(@as(f64, 1.00), out2.fcaor); // Complete capital diversion
    try std.testing.expect(!std.math.isNan(out2.remaining_resources));
    try std.testing.expect(!std.math.isInf(out2.remaining_resources));
}

test "ResourceEngine: zero population resilience" {
    var engine = ResourceEngine.init();
    const initial_nr = engine.state.remaining_resources;

    // Zero population stepping
    const out = engine.step(0.0, 500.0, 1.0);

    try std.testing.expectEqual(@as(f64, 0.0), out.resource_usage_rate);
    try std.testing.expectEqual(initial_nr, out.remaining_resources);
    try std.testing.expectEqual(initial_nr, engine.state.remaining_resources);
    try std.testing.expectEqual(@as(f64, 1.0), out.nrfr);
    try std.testing.expectEqual(@as(f64, 0.05), out.fcaor);
    try std.testing.expect(!std.math.isNan(out.remaining_resources));
}

test "ResourceEngine: high IOPC saturation (PCRUM -> 7.0)" {
    // Check saturation plateau at exactly 1600.0
    try std.testing.expectEqual(@as(f64, 7.0), ResourceEngine.interpolatePCRUM(1600.0));

    // Check extreme wealth / saturation beyond table bounds
    try std.testing.expectEqual(@as(f64, 7.0), ResourceEngine.interpolatePCRUM(2000.0));
    try std.testing.expectEqual(@as(f64, 7.0), ResourceEngine.interpolatePCRUM(100_000.0));
    try std.testing.expectEqual(@as(f64, 7.0), ResourceEngine.interpolatePCRUM(1.0e9));
}

test "ResourceEngine: table knot exactness for PCRUM" {
    // Known World3 table values
    try std.testing.expectApproxEqAbs(@as(f64, 0.00), ResourceEngine.interpolatePCRUM(0.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.85), ResourceEngine.interpolatePCRUM(200.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.60), ResourceEngine.interpolatePCRUM(400.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4.40), ResourceEngine.interpolatePCRUM(600.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5.40), ResourceEngine.interpolatePCRUM(800.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 6.20), ResourceEngine.interpolatePCRUM(1000.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 6.80), ResourceEngine.interpolatePCRUM(1200.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 7.00), ResourceEngine.interpolatePCRUM(1400.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 7.00), ResourceEngine.interpolatePCRUM(1600.0), 1.0e-9);

    // Linear midpoints verified against PyWorld3 reference
    try std.testing.expectApproxEqAbs(@as(f64, 0.425), ResourceEngine.interpolatePCRUM(100.0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 1.725), ResourceEngine.interpolatePCRUM(300.0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 3.500), ResourceEngine.interpolatePCRUM(500.0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 4.900), ResourceEngine.interpolatePCRUM(700.0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 5.800), ResourceEngine.interpolatePCRUM(900.0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 6.500), ResourceEngine.interpolatePCRUM(1100.0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 6.900), ResourceEngine.interpolatePCRUM(1300.0), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 7.000), ResourceEngine.interpolatePCRUM(1500.0), 1.0e-6);
}

test "ResourceEngine: table knot exactness for FCAOR" {
    // Known World3 table values
    try std.testing.expectApproxEqAbs(@as(f64, 1.00), ResourceEngine.interpolateFCAOR(0.0), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.90), ResourceEngine.interpolateFCAOR(0.1), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.70), ResourceEngine.interpolateFCAOR(0.2), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.50), ResourceEngine.interpolateFCAOR(0.3), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.20), ResourceEngine.interpolateFCAOR(0.4), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.10), ResourceEngine.interpolateFCAOR(0.5), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), ResourceEngine.interpolateFCAOR(0.6), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), ResourceEngine.interpolateFCAOR(0.7), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), ResourceEngine.interpolateFCAOR(0.8), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), ResourceEngine.interpolateFCAOR(0.9), 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), ResourceEngine.interpolateFCAOR(1.0), 1.0e-9);

    // Linear midpoints verified against PyWorld3 reference
    try std.testing.expectApproxEqAbs(@as(f64, 0.950), ResourceEngine.interpolateFCAOR(0.05), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.800), ResourceEngine.interpolateFCAOR(0.15), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.600), ResourceEngine.interpolateFCAOR(0.25), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.350), ResourceEngine.interpolateFCAOR(0.35), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.150), ResourceEngine.interpolateFCAOR(0.45), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.075), ResourceEngine.interpolateFCAOR(0.55), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.050), ResourceEngine.interpolateFCAOR(0.65), 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.050), ResourceEngine.interpolateFCAOR(0.85), 1.0e-6);
}

test "ResourceEngine: invariant range assertions across dynamic spectrum" {
    var engine = ResourceEngine.init();

    // Iterate across 500 variable conditions
    var pop: f64 = 1.0e8;
    while (pop <= 1.0e10) : (pop += 5.0e8) {
        var iopc: f64 = 0.0;
        while (iopc <= 2000.0) : (iopc += 200.0) {
            const out = engine.step(pop, iopc, 1.0);

            // Invariant 1: NRFR in [0.0, 1.0]
            try std.testing.expect(out.nrfr >= 0.0);
            try std.testing.expect(out.nrfr <= 1.0);

            // Invariant 2: FCAOR in [0.05, 1.00]
            try std.testing.expect(out.fcaor >= 0.05);
            try std.testing.expect(out.fcaor <= 1.00);

            // Invariant 3: Non-negative stock
            try std.testing.expect(out.remaining_resources >= 0.0);

            // Numerical safety: Finite numbers (no NaN, no Inf)
            try std.testing.expect(!std.math.isNan(out.remaining_resources));
            try std.testing.expect(!std.math.isInf(out.remaining_resources));
            try std.testing.expect(!std.math.isNan(out.fcaor));
            try std.testing.expect(!std.math.isInf(out.fcaor));
            try std.testing.expect(!std.math.isNan(out.pcrum));
            try std.testing.expect(!std.math.isInf(out.pcrum));
        }
    }
}

test "ResourceEngine: monotonic depletion invariant under positive usage" {
    var engine = ResourceEngine.init();
    const pop: f64 = 5.0e9;
    const iopc: f64 = 400.0;
    const dt: f64 = 1.0;

    var prev_nr = engine.state.remaining_resources;
    var prev_nrfr: f64 = 1.0;
    var prev_fcaor: f64 = 0.05;

    for (0..100) |_| {
        const out = engine.step(pop, iopc, dt);

        // Under positive usage, remaining resources must strictly decrease (or stay 0 once depleted)
        try std.testing.expect(out.remaining_resources <= prev_nr);
        try std.testing.expect(out.nrfr <= prev_nrfr);

        // FCAOR must monotonically increase (or stay constant once at max/min)
        try std.testing.expect(out.fcaor >= prev_fcaor);

        prev_nr = out.remaining_resources;
        prev_nrfr = out.nrfr;
        prev_fcaor = out.fcaor;
    }
}

test "ResourceEngine: adversarial input resilience (negatives, NaN, Inf)" {
    var engine = ResourceEngine.init();
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);

    // Negative population must not generate resources
    const initial_nr = engine.state.remaining_resources;
    const out_neg_pop = engine.step(-1.0e9, 500.0, 1.0);
    try std.testing.expectEqual(@as(f64, 0.0), out_neg_pop.resource_usage_rate);
    try std.testing.expectEqual(initial_nr, out_neg_pop.remaining_resources);

    // Negative IOPC must be treated as 0.0
    const out_neg_iopc = engine.step(1.0e9, -500.0, 1.0);
    try std.testing.expectEqual(@as(f64, 0.0), out_neg_iopc.pcrum);
    try std.testing.expectEqual(@as(f64, 0.0), out_neg_iopc.resource_usage_rate);

    // Negative dt must not cause reverse time travel
    const out_neg_dt = engine.step(1.0e9, 500.0, -1.0);
    try std.testing.expectEqual(initial_nr, out_neg_dt.remaining_resources);

    // NaN / Inf inputs must not poison engine state
    const out_nan = engine.step(nan, nan, 1.0);
    try std.testing.expect(!std.math.isNan(out_nan.remaining_resources));
    try std.testing.expect(!std.math.isNan(out_nan.fcaor));

    const out_inf = engine.step(inf, 500.0, 1.0);
    try std.testing.expect(!std.math.isNan(out_inf.remaining_resources));
    try std.testing.expect(!std.math.isInf(out_inf.remaining_resources));

    // Guardrail safeDiv tests
    try std.testing.expectEqual(@as(f64, 99.0), safeDiv(100.0, 0.0, 99.0));
    try std.testing.expectEqual(@as(f64, 99.0), safeDiv(nan, 10.0, 99.0));
    try std.testing.expectEqual(@as(f64, 99.0), safeDiv(10.0, nan, 99.0));
    try std.testing.expectEqual(@as(f64, 99.0), safeDiv(10.0, inf, 99.0));
    try std.testing.expectEqual(@as(f64, 5.0), safeDiv(50.0, 10.0, 99.0));
}

test "ResourceCurves: zero allocation and memory layout verification" {
    // Plain Old Data size checks
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ResourceState));
    try std.testing.expectEqual(@as(usize, 832), @sizeOf(ResourceCurves));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(ResourceOutput));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ResourceEngine));

    // Cache line alignment
    try std.testing.expectEqual(@as(usize, 64), @alignOf(ResourceCurves));

    // Verify curve profile values
    const curves = generateDefaultCurves();
    try std.testing.expectEqual(@as(f64, 0.15), curves.resource_usage_profile[0]);  // Infant
    try std.testing.expectEqual(@as(f64, 1.00), curves.resource_usage_profile[30]); // Adult
    try std.testing.expect(curves.resource_usage_profile[80] < 1.00);               // Elderly
    try std.testing.expect(curves.resource_usage_profile[80] >= 0.50);

    // Test vector dot-product
    var males = [_]f64{100.0} ** 104;
    var females = [_]f64{100.0} ** 104;
    const eff = ResourceEngine.calculateEffectivePopulation(&males, &females, &curves);
    try std.testing.expect(eff > 0.0);
}
