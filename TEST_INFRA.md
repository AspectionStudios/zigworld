# E2E Test Infra: PyWorld5 (Zigworld)

## Test Philosophy
- Opaque-box, requirement-driven. Derived strictly from `ORIGINAL_REQUEST.md` and user specifications.
- Methodology: Category-Partition + Boundary Value Analysis + Pairwise Combinatorial + Real-World Workload Testing.
- Zero reliance on internal implementation details; tests exercise public interfaces, compilation commands, and runtime outputs.

## Feature Inventory
| # | Feature | Source (Requirement) | Tier 1 | Tier 2 | Tier 3 | Tier 4 |
|---|---------|----------------------|:------:|:------:|:------:|:------:|
| 1 | Resources Engine (NR, NRUR, FCAOR) | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ | ✓ |
| 2 | Pollution Engine (PPOL, Delay3, PPASR) | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ | ✓ |
| 3 | Agriculture Engine (Land, Yield, Food) | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ | ✓ |
| 4 | Collision-Zone [104]f64 Interfaces | ORIGINAL_REQUEST §R1 | 5 | 5 | ✓ | ✓ |
| 5 | Unified 5-Sector Synchronous Stepping | ORIGINAL_REQUEST §R2 | 5 | 5 | ✓ | ✓ |
| 6 | Sub-1,500 ns/step Zero-Allocation Performance | ORIGINAL_REQUEST §R3, Acceptance §1 | 5 | 5 | ✓ | ✓ |
| 7 | Demographic & Numerical Safety (no NaN/Inf) | ORIGINAL_REQUEST Acceptance §2 | 5 | 5 | ✓ | ✓ |

## Test Architecture
- **Compiler**: `/Users/kratos/Downloads/zig-compiler/zig`
- **Build Target**: `/Users/kratos/Downloads/zig-compiler/zig build-exe -O ReleaseFast src/main_padded.zig`
- **Unit Test Runner**: `/Users/kratos/Downloads/zig-compiler/zig test <file.zig>`
- **E2E Test Runner**: `tests/run_all_e2e.sh` (or `zig test tests/test_all_e2e.zig`)
- **Pass/Fail Semantics**: 0 compiler warnings/errors, exit code 0, all assertions pass, benchmark output < 1,500 ns/step, final population & economy outputs are finite positive numbers.

## Real-World Application Scenarios (Tier 4)
| # | Scenario | Features Exercised | Complexity |
|---|----------|--------------------|------------|
| 1 | Standard Run 1900–2100 | Baseline resource depletion, industrial growth, pollution crest, and demographic peak | High |
| 2 | Resource Depletion Shock | Accelerated resource use driving rapid FCAOR surge to >0.90, precipitating capital starvation | High |
| 3 | Acute Toxic Pollution Crisis | Industrial/agricultural emissions surge causing delayed severe infant/elderly mortality spikes | High |
| 4 | Famine / Caloric Deprivation Collapse | Agricultural input shortfall and erosion causing catastrophic food ratio deficit and infant starvation | High |
| 5 | Sustainable / Steady-State Stabilized Run | Balanced technological inputs, reduced emission factors, and sustainable population equilibrium | High |

## Coverage Thresholds
- Tier 1: ≥ 5 test cases per feature (35 test cases)
- Tier 2: ≥ 5 test cases per feature (35 test cases)
- Tier 3: Pairwise coverage across major feature interactions (≥ 7 test cases)
- Tier 4: ≥ 5 realistic application-level collapse/stabilization scenarios
- **Total Minimum Test Cases**: ≥ 82 test cases
