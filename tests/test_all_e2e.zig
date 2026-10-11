const std = @import("std");

// Master E2E Test Suite Aggregator for PyWorld5 (Zigworld)
// Covering Tiers 1-4 per TEST_INFRA.md:
// - Tier 1: Feature Isolation Coverage (35 tests across 7 features)
// - Tier 2: Boundary & Corner Cases (35 tests across 7 features)
// - Tier 3: Pairwise Cross-Feature Interactions (9 interaction tests)
// - Tier 4: Real-World Planetary Application Scenarios (5 collapse/stabilization scenarios)

test {
    _ = @import("test_tier1_features.zig");
    _ = @import("test_tier2_boundaries.zig");
    _ = @import("test_tier3_interactions.zig");
    _ = @import("test_tier4_scenarios.zig");
}
