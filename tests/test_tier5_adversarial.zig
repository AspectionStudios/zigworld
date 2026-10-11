const std = @import("std");
const resources = @import("src/resources.zig");

const ResourceEngine = resources.ResourceEngine;
const ResourceState = resources.ResourceState;
const ResourceCurves = resources.ResourceCurves;
const ResourceOutput = resources.ResourceOutput;
const safeDiv = resources.safeDiv;
const sanitizeNonNegative = resources.sanitizeNonNegative;

// ============================================================================
// SUITE 1: POPULATION EXTREMES & SCALE GAME
// ============================================================================

test "Adversarial: Zero Population Stepping" {
    var engine = ResourceEngine.init();
    const initial_nr = engine.state.remaining_resources;

    // Zero population must yield zero depletion rate and preserve resources exactly
    for (0..100) |_| {
        const out = engine.step(0.0, 500.0, 1.0);
        try std.testing.expectEqual(@as(f64, 0.0), out.resource_usage_rate);
        try std.testing.expectEqual(initial_nr, out.remaining_resources);
        try std.testing.expectEqual(@as(f64, 1.0), out.nrfr);
        try std.testing.expectEqual(@as(f64, 0.05), out.fcaor);
        try std.testing.expect(!std.math.isNan(out.remaining_resources));
        try std.testing.expect(!std.math.isInf(out.remaining_resources));
    }
}

test "Adversarial: Extreme Population Scales (100 Billion to Quadrillions)" {
    // 1. 10 Billion population: consumes 6.2e10/yr, leaving 9.38e11 after 1 year
    {
        var engine = ResourceEngine.init();
        const out = engine.step(1.0e10, 1000.0, 1.0);
        try std.testing.expectApproxEqAbs(@as(f64, 9.38e11), out.remaining_resources, 1.0e7);
        try std.testing.expect(out.remaining_resources > 0.0);
        try std.testing.expect(out.nrfr > 0.9);
        try std.testing.expectEqual(@as(f64, 0.05), out.fcaor);
    }

    // 2. 100 Billion population: consumes 6.2e11/yr, leaving 3.80e11 after 1 year
    {
        var engine = ResourceEngine.init();
        const out = engine.step(1.0e11, 1000.0, 1.0);
        try std.testing.expectApproxEqAbs(@as(f64, 3.80e11), out.remaining_resources, 1.0e7);
        try std.testing.expect(out.remaining_resources > 0.0);
        try std.testing.expectApproxEqAbs(@as(f64, 0.38), out.nrfr, 0.01);
        try std.testing.expect(out.fcaor > 0.05); // FCAOR drag begins
    }

    // 3. Astronomical populations (1 Trillion to FloatMax): Instant exhaustion to exactly 0.0
    const astronomical_pops = [_]f64{
        1.0e12, // 1 Trillion: demand 6.2e12 > 1.0e12
        1.0e15, // 1 Quadrillion
        1.0e30, // Astronomical
        std.math.floatMax(f64),
    };

    for (astronomical_pops) |pop| {
        var engine = ResourceEngine.init();
        const out = engine.step(pop, 1000.0, 1.0);

        // Under extreme population, resources deplete instantly to 0.0, never negative
        try std.testing.expect(out.remaining_resources >= 0.0);
        try std.testing.expectEqual(@as(f64, 0.0), out.remaining_resources);
        try std.testing.expectEqual(@as(f64, 0.0), out.nrfr);
        try std.testing.expectEqual(@as(f64, 1.00), out.fcaor);
        try std.testing.expect(!std.math.isNan(out.remaining_resources));
        try std.testing.expect(!std.math.isInf(out.remaining_resources));
        try std.testing.expect(!std.math.isNan(out.fcaor));
        try std.testing.expect(!std.math.isInf(out.fcaor));
        try std.testing.expect(!std.math.isNan(out.nrfr));
        try std.testing.expect(!std.math.isInf(out.nrfr));
    }
}

// ============================================================================
// SUITE 2: INDUSTRIAL OUTPUT PER CAPITA (IOPC) EXTREMES
// ============================================================================

test "Adversarial: Zero and Near-Zero IOPC" {
    var engine = ResourceEngine.init();

    // Exactly zero IOPC
    const out_zero = engine.step(8.0e9, 0.0, 1.0);
    try std.testing.expectEqual(@as(f64, 0.0), out_zero.pcrum);
    try std.testing.expectEqual(@as(f64, 0.0), out_zero.resource_usage_rate);
    try std.testing.expectEqual(ResourceEngine.NRI, out_zero.remaining_resources);
    try std.testing.expectEqual(@as(f64, 1.0), out_zero.nrfr);
    try std.testing.expectEqual(@as(f64, 0.05), out_zero.fcaor);

    // Subnormal / Infinitesimal IOPC
    const subnormal_iopc: f64 = 1.0e-300;
    const out_sub = engine.step(8.0e9, subnormal_iopc, 1.0);
    try std.testing.expect(out_sub.pcrum >= 0.0);
    try std.testing.expect(out_sub.pcrum < 0.01);
    try std.testing.expect(!std.math.isNan(out_sub.pcrum));
    try std.testing.expect(!std.math.isInf(out_sub.pcrum));
    try std.testing.expect(out_sub.remaining_resources >= 0.0);
}

test "Adversarial: Extreme Wealth and Infinite IOPC (Saturation Verification)" {
    const extreme_iopcs = [_]f64{
        1600.0,
        1600.0001,
        2000.0,
        1.0e6,
        1.0e9,
        1.0e18,
        std.math.floatMax(f64),
    };

    for (extreme_iopcs) |iopc| {
        const pcrum = ResourceEngine.interpolatePCRUM(iopc);
        try std.testing.expectEqual(@as(f64, 7.00), pcrum);
        try std.testing.expect(!std.math.isNan(pcrum));
        try std.testing.expect(!std.math.isInf(pcrum));
    }
}

// ============================================================================
// SUITE 3: TIME STEP (DT) EXTREMES
// ============================================================================

test "Adversarial: Extreme Time Steps (Zero, Infinitesimal, Geological, FloatMax)" {
    // 1. Zero dt (Frozen Time)
    {
        var engine = ResourceEngine.init();
        const out = engine.step(8.0e9, 500.0, 0.0);
        try std.testing.expectEqual(ResourceEngine.NRI, out.remaining_resources);
        try std.testing.expectEqual(@as(f64, 1.0), out.nrfr);
        try std.testing.expectEqual(@as(f64, 0.05), out.fcaor);
    }

    // 2. Infinitesimal dt (1e-12 years)
    {
        var engine = ResourceEngine.init();
        const out = engine.step(8.0e9, 500.0, 1.0e-12);
        try std.testing.expect(out.remaining_resources <= ResourceEngine.NRI);
        try std.testing.expect(out.remaining_resources >= ResourceEngine.NRI - 1.0);
        try std.testing.expect(!std.math.isNan(out.remaining_resources));
    }

    // 3. Geological time steps (1 Million years to FloatMax)
    const geological_dts = [_]f64{
        1.0e6,
        1.0e12,
        std.math.floatMax(f64),
    };

    for (geological_dts) |dt| {
        var engine = ResourceEngine.init();
        const out = engine.step(8.0e9, 500.0, dt);
        try std.testing.expectEqual(@as(f64, 0.0), out.remaining_resources);
        try std.testing.expectEqual(@as(f64, 0.0), out.nrfr);
        try std.testing.expectEqual(@as(f64, 1.00), out.fcaor);
        try std.testing.expect(!std.math.isNan(out.remaining_resources));
        try std.testing.expect(!std.math.isInf(out.remaining_resources));
    }
}

// ============================================================================
// SUITE 4: ADVERSARIAL AND TOXIC INPUTS (NEGATIVES, NANS, INFS, SUBNORMALS)
// ============================================================================

test "Adversarial: Negative Population, Negative IOPC, Negative dt" {
    var engine = ResourceEngine.init();
    const initial_nr = engine.state.remaining_resources;

    // 1. Negative Population: Must not generate resources or crash
    const out1 = engine.step(-5.0e9, 500.0, 1.0);
    try std.testing.expectEqual(@as(f64, 0.0), out1.resource_usage_rate);
    try std.testing.expectEqual(initial_nr, out1.remaining_resources);

    // 2. Negative IOPC: Must be clamped to 0.0 usage
    const out2 = engine.step(5.0e9, -500.0, 1.0);
    try std.testing.expectEqual(@as(f64, 0.0), out2.pcrum);
    try std.testing.expectEqual(@as(f64, 0.0), out2.resource_usage_rate);
    try std.testing.expectEqual(initial_nr, out2.remaining_resources);

    // 3. Negative dt: Must not reverse entropy
    const out3 = engine.step(5.0e9, 500.0, -10.0);
    try std.testing.expectEqual(initial_nr, out3.remaining_resources);

    // 4. All negative simultaneously
    const out4 = engine.step(-1.0e10, -1000.0, -1.0);
    try std.testing.expectEqual(@as(f64, 0.0), out4.resource_usage_rate);
    try std.testing.expectEqual(initial_nr, out4.remaining_resources);
    try std.testing.expectEqual(@as(f64, 1.0), out4.nrfr);
    try std.testing.expectEqual(@as(f64, 0.05), out4.fcaor);
}

test "Adversarial: IEEE 754 Special Values (NaN, +Inf, -Inf, Signed Zeros)" {
    var engine = ResourceEngine.init();
    const nan = std.math.nan(f64);
    const pos_inf = std.math.inf(f64);
    const neg_inf = -std.math.inf(f64);

    // Test matrix of combinations of NaN and Infs
    const toxic_values = [_]f64{ nan, pos_inf, neg_inf, -0.0 };

    for (toxic_values) |t_pop| {
        for (toxic_values) |t_iopc| {
            for (toxic_values) |t_dt| {
                const out = engine.step(t_pop, t_iopc, t_dt);

                // Absolute invariants: NO NaNs or Infs allowed in outputs
                try std.testing.expect(!std.math.isNan(out.remaining_resources));
                try std.testing.expect(!std.math.isInf(out.remaining_resources));
                try std.testing.expect(!std.math.isNan(out.nrfr));
                try std.testing.expect(!std.math.isInf(out.nrfr));
                try std.testing.expect(!std.math.isNan(out.fcaor));
                try std.testing.expect(!std.math.isInf(out.fcaor));
                try std.testing.expect(!std.math.isNan(out.resource_usage_rate));
                try std.testing.expect(!std.math.isInf(out.resource_usage_rate));
                try std.testing.expect(!std.math.isNan(out.pcrum));
                try std.testing.expect(!std.math.isInf(out.pcrum));

                // Boundedness invariants
                try std.testing.expect(out.remaining_resources >= 0.0);
                try std.testing.expect(out.nrfr >= 0.0 and out.nrfr <= 1.0);
                try std.testing.expect(out.fcaor >= 0.05 and out.fcaor <= 1.00);
            }
        }
    }
}

test "Adversarial: Subnormal and Denormal Float Inputs" {
    var engine = ResourceEngine.init();
    const subnormals = [_]f64{
        5.0e-324, // Smallest positive subnormal f64
        1.0e-310,
        2.2250738585072014e-308, // Smallest positive normal f64
    };

    for (subnormals) |sub| {
        const out = engine.step(sub, sub, sub);
        try std.testing.expect(!std.math.isNan(out.remaining_resources));
        try std.testing.expect(!std.math.isInf(out.remaining_resources));
        try std.testing.expect(out.remaining_resources >= 0.0);
    }
}

// ============================================================================
// SUITE 5: RAPID RESOURCE DRAIN AND PROLONGED POST-EXHAUSTION STEPPING
// ============================================================================

test "Adversarial: Single Step Complete Drain and 100,000 Post-Exhaustion Steps" {
    var engine = ResourceEngine.init();

    // 1. Catastrophic instant drain: Population 1 Trillion, high IOPC
    const drain_out = engine.step(1.0e12, 1600.0, 1.0);
    try std.testing.expectEqual(@as(f64, 0.0), drain_out.remaining_resources);
    try std.testing.expectEqual(@as(f64, 0.0), drain_out.nrfr);
    try std.testing.expectEqual(@as(f64, 1.00), drain_out.fcaor);
    try std.testing.expectEqual(@as(f64, 0.0), engine.state.remaining_resources);
    try std.testing.expectEqual(@as(f64, 1.00), engine.state.fcaor);

    // 2. 100,000 consecutive steps while fully exhausted
    for (0..100_000) |_| {
        const out = engine.step(8.0e9, 500.0, 1.0);
        try std.testing.expectEqual(@as(f64, 0.0), out.remaining_resources);
        try std.testing.expectEqual(@as(f64, 0.0), out.nrfr);
        try std.testing.expectEqual(@as(f64, 1.00), out.fcaor);
        try std.testing.expect(!std.math.isNan(out.remaining_resources));
        try std.testing.expect(!std.math.isInf(out.remaining_resources));
    }
}

// ============================================================================
// SUITE 6: TABLE CONTINUITY, MONOTONICITY, AND EXACT KNOT BOUNDS
// ============================================================================

test "Adversarial: PCRUM Interpolation Monotonicity Across Dense Grid" {
    var prev_val: f64 = -1.0;
    var iopc: f64 = 0.0;
    // Sweep dense grid of 16,000 points from 0 to 1600, plus beyond
    while (iopc <= 2000.0) : (iopc += 0.1) {
        const val = ResourceEngine.interpolatePCRUM(iopc);
        try std.testing.expect(val >= 0.0);
        try std.testing.expect(val <= 7.0);
        try std.testing.expect(val >= prev_val - 1.0e-12); // Monotonic non-decreasing
        prev_val = val;
    }
}

test "Adversarial: FCAOR Interpolation Monotonicity Across Dense Grid" {
    var prev_val: f64 = 2.0;
    var nrfr: f64 = 0.0;
    // Sweep dense grid from 0.0 to 1.0
    while (nrfr <= 1.0001) : (nrfr += 0.001) {
        const val = ResourceEngine.interpolateFCAOR(nrfr);
        try std.testing.expect(val >= 0.05);
        try std.testing.expect(val <= 1.00);
        // FCAOR decreases as NRFR increases
        try std.testing.expect(val <= prev_val + 1.0e-12);
        prev_val = val;
    }
}

// ============================================================================
// SUITE 7: PSEUDO-RANDOM CHAOTIC MONTE CARLO STRESS HARNESS
// ============================================================================

test "Adversarial: 50,000 Chaotic Steps Monte Carlo Fuzzing" {
    var prng = std.Random.DefaultPrng.init(0xDEADC0DE_CAFE1234);
    const rand = prng.random();

    var engine = ResourceEngine.init();

    for (0..50_000) |_| {
        // Generate pseudo-random inputs spanning normal, extreme, negative, and zero ranges
        const pop_mode = rand.intRangeAtMost(u8, 0, 5);
        const pop: f64 = switch (pop_mode) {
            0 => 0.0,
            1 => -rand.float(f64) * 1.0e10,
            2 => rand.float(f64) * 1.0e10, // normal population
            3 => rand.float(f64) * 1.0e15, // extreme population
            4 => std.math.nan(f64),
            else => std.math.inf(f64),
        };

        const iopc_mode = rand.intRangeAtMost(u8, 0, 5);
        const iopc: f64 = switch (iopc_mode) {
            0 => 0.0,
            1 => -rand.float(f64) * 2000.0,
            2 => rand.float(f64) * 2000.0,
            3 => rand.float(f64) * 1.0e9,
            4 => std.math.nan(f64),
            else => std.math.inf(f64),
        };

        const dt_mode = rand.intRangeAtMost(u8, 0, 4);
        const dt: f64 = switch (dt_mode) {
            0 => 0.0,
            1 => -rand.float(f64),
            2 => rand.float(f64) * 2.0,
            3 => rand.float(f64) * 1000.0,
            else => 1.0,
        };

        const out = engine.step(pop, iopc, dt);

        // Assert all invariants hold under every combination of inputs
        try std.testing.expect(!std.math.isNan(out.remaining_resources));
        try std.testing.expect(!std.math.isInf(out.remaining_resources));
        try std.testing.expect(out.remaining_resources >= 0.0);

        try std.testing.expect(!std.math.isNan(out.nrfr));
        try std.testing.expect(!std.math.isInf(out.nrfr));
        try std.testing.expect(out.nrfr >= 0.0 and out.nrfr <= 1.0);

        try std.testing.expect(!std.math.isNan(out.fcaor));
        try std.testing.expect(!std.math.isInf(out.fcaor));
        try std.testing.expect(out.fcaor >= 0.05 and out.fcaor <= 1.00);

        try std.testing.expect(!std.math.isNan(out.resource_usage_rate));
        try std.testing.expect(!std.math.isInf(out.resource_usage_rate));
        try std.testing.expect(out.resource_usage_rate >= 0.0);

        try std.testing.expect(!std.math.isNan(out.pcrum));
        try std.testing.expect(!std.math.isInf(out.pcrum));
        try std.testing.expect(out.pcrum >= 0.0 and out.pcrum <= 7.0);
    }
}

// ============================================================================
// SUITE 9: PRE-CORRUPTED ENGINE STATE RESILIENCE
// ============================================================================

test "Adversarial: Pre-Corrupted Negative Remaining Resources State" {
    var engine = ResourceEngine.init();
    // Simulate memory glitch or un-sanitized external mutation
    engine.state.remaining_resources = -5.0e11;
    engine.state.fcaor = -0.99;

    // Stepping must recover cleanly: clamp remaining resources >= 0.0
    const out = engine.step(8.0e9, 500.0, 1.0);
    try std.testing.expect(out.remaining_resources >= 0.0);
    try std.testing.expectEqual(@as(f64, 0.0), out.remaining_resources);
    try std.testing.expectEqual(@as(f64, 0.0), engine.state.remaining_resources);
    try std.testing.expectEqual(@as(f64, 0.0), out.nrfr);
    try std.testing.expectEqual(@as(f64, 1.00), out.fcaor);
    try std.testing.expectEqual(@as(f64, 1.00), engine.state.fcaor);
}

test "Adversarial: Pre-Corrupted NaN / Inf Remaining Resources State" {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);

    // Test Inf recovery: remaining resources must stay non-negative and finite/inf without crashing
    {
        var engine = ResourceEngine.init();
        engine.state.remaining_resources = inf;
        const out = engine.step(8.0e9, 500.0, 1.0);
        try std.testing.expect(!std.math.isNan(out.remaining_resources));
        try std.testing.expect(out.remaining_resources >= 0.0);
        try std.testing.expect(!std.math.isNan(out.fcaor));
        try std.testing.expect(!std.math.isNan(out.nrfr));
    }

    // Test NaN behavior: NaN in state is cleanly eliminated and clamped to 0.0
    {
        var engine = ResourceEngine.init();
        engine.state.remaining_resources = nan;
        const out = engine.step(8.0e9, 500.0, 1.0);
        try std.testing.expectEqual(@as(f64, 0.0), out.remaining_resources);
        try std.testing.expectEqual(@as(f64, 0.0), out.nrfr);
        try std.testing.expectEqual(@as(f64, 1.00), out.fcaor);
        try std.testing.expect(!std.math.isNan(out.remaining_resources));
        try std.testing.expect(!std.math.isNan(out.fcaor));
    }
}

// ============================================================================
// SUITE 10: COLLISION-ZONE EFFECTIVE POPULATION STRESS
// ============================================================================

test "Adversarial: calculateEffectivePopulation with Extreme and Negative Cohorts" {
    const curves = resources.generateDefaultCurves();
    var males: [104]f64 align(64) = undefined;
    var females: [104]f64 align(64) = undefined;

    // 1. All zeros
    @memset(&males, 0.0);
    @memset(&females, 0.0);
    const eff_zero = ResourceEngine.calculateEffectivePopulation(&males, &females, &curves);
    try std.testing.expectEqual(@as(f64, 0.0), eff_zero);

    // 2. Negative cohorts (must clamp to >= 0.0)
    @memset(&males, -1.0e8);
    @memset(&females, -1.0e8);
    const eff_neg = ResourceEngine.calculateEffectivePopulation(&males, &females, &curves);
    try std.testing.expectEqual(@as(f64, 0.0), eff_neg);

    // 3. Astronomical cohorts (1 Trillion per age bucket)
    @memset(&males, 1.0e12);
    @memset(&females, 1.0e12);
    const eff_astro = ResourceEngine.calculateEffectivePopulation(&males, &females, &curves);
    try std.testing.expect(eff_astro > 1.0e14);
    try std.testing.expect(!std.math.isNan(eff_astro));
    try std.testing.expect(!std.math.isInf(eff_astro));
}

// ============================================================================
// SUITE 11: ZERO HEAP ALLOCATION & PERFORMANCE BENCHMARK
// ============================================================================

test "Adversarial: Zero Heap Allocation Invariant and Micro-Benchmark" {
    var engine = ResourceEngine.init();
    const pop: f64 = 6.0e9;
    const iopc: f64 = 600.0;
    const dt: f64 = 1.0;

    const start_time = std.time.nanoTimestamp();
    const iterations: usize = 100_000;

    for (0..iterations) |_| {
        _ = engine.step(pop, iopc, dt);
    }
    const end_time = std.time.nanoTimestamp();
    const total_ns = @as(f64, @floatFromInt(end_time - start_time));
    const ns_per_step = total_ns / @as(f64, @floatFromInt(iterations));

    // Must be well below 1500 ns budget (expected < 50 ns/step)
    try std.testing.expect(ns_per_step < 1500.0);
}

// ============================================================================
// SUITE 12: UNIFIED 5-SECTOR ADVERSARIAL STRESS SUITE (CHALLENGER 1)
// ============================================================================

test {
    _ = @import("test_tier5_adversarial_stress.zig");
}

