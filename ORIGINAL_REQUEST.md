# Original User Request

## 2026-10-11T10:21:50Z

# Teamwork Project Prompt — Draft

> Status: Launched
> Goal: Craft prompt → get user approval → delegate to teamwork_preview
> Requested team: Full team

Implement the Agriculture/Food, Resources, and Pollution sectors for PyWorld5 (Zigworld) in Zig. These must integrate perfectly with the existing SIMD-aligned Population and Economy engines while maintaining the sub-microsecond zero-allocation benchmark speeds.

Working directory: /Users/kratos/Downloads/zigworld
Integrity mode: development

## Requirements

### R1. Implement Missing Sectors
Build the Agriculture, Resources, and Pollution engines in Zig. Use the "Collision-Zone" architecture: wherever macroeconomic variables interface with human beings, use the padded `[104]f64` array structure (e.g., age-specific food demand, age-specific pollution mortality).

### R2. Unified Engine Hookup
Wire the new sectors into `src/main_padded.zig` so that Population, Economy, Agriculture, Resources, and Pollution all update synchronously in a single `for` loop.

### R3. Sub-Microsecond Execution
The code must strictly adhere to the `benchmark-swarm-protocol`. Zero heap allocations are allowed during the main execution loop. The entire planetary simulation must remain highly parallelizable and ridiculously fast.

## Acceptance Criteria

### Performance & Compilation
- [ ] `zig build-exe -O ReleaseFast src/main_padded.zig` compiles with 0 errors and 0 warnings.
- [ ] The compiled benchmark outputs an "Average time per 1-year step" of less than 1,500 nanoseconds (1.5 microseconds).

### Demographic Safety
- [ ] Running the benchmark prints valid floating-point numbers for Final Population and Economy Outputs (No `NaN`, `Inf`, or `0.00` if the population hasn't completely died).
