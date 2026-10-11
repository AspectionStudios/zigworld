# Project: PyWorld5 (Zigworld) Expansion

## Architecture
PyWorld5 (Zigworld) is a high-performance planetary simulation engine written in Zig 0.13.0.
The system models 5 interdependent sectors:
1. **Population**: Single-year cohort demographics (ages 0 to 103+) using SIMD-aligned `[104]f64` arrays for male and female populations.
2. **Economy**: Industrial and service capital stocks driving industrial output ($IO$), service output ($SO$), and total energy demand ($TWh$).
3. **Resources**: Non-renewable resource stock ($NR$), depletion rate ($NRUR$), and capital extraction drag ($FCAOR$).
4. **Pollution**: Persistent pollution stock ($PPOL$), 3rd-order physical transmission delay (`Delay3`), nonlinear assimilation ($PPASR$), and age-specific toxicological mortality.
5. **Agriculture**: Arable land ($AL$), fertility ($LFERT$), agricultural inputs ($AI$), food production ($F$), and age-specific caloric satisfaction and famine mortality.

### Collision-Zone Architecture
Wherever macroeconomic variables interface with human populations, the interface is mediated by SIMD-aligned, cache-padded `[104]f64` arrays:
- `labor_participation: [104]f64` (Economy ↔ Population)
- `energy_demand_profile: [104]f64` (Economy ↔ Population)
- `food_demand: [104]f64` (Agriculture ↔ Population)
- `food_mortality_vulnerability: [104]f64` (Agriculture ↔ Population)
- `pollution_vulnerability: [104]f64` (Pollution ↔ Population)
- `resource_usage_profile: [104]f64` (Resources ↔ Population)

All arrays are padded to 104 `f64` elements (832 bytes = 13 x 64-byte L1 cache lines, divisible by 8 for AVX-512, 4 for AVX2, and 2 for ARM NEON) ensuring zero scalar remainder loops and zero cache line splits.

### Memory & Execution Architecture
- **Zero Heap Allocation**: All states and curves are Plain Old Data (POD) structs allocated on the stack. The entire 5-sector state is ~1,808 bytes, residing 100% in L1 Data Cache.
- **Synchronous Single Loop**: Demographics, Economy, Resources, Agriculture, and Pollution update synchronously in a single `for (0..years_per_sim)` loop in `src/main_padded.zig`.
- **Performance Budget**: Target < 1,500 ns / 1-year step in `zig build-exe -O ReleaseFast`. (Baseline is ~661–689 ns; projected 5-sector time is ~850–950 ns).

---

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | Non-Renewable Resource Stock & ODE | Depletion ODE ($dNR/dt = -NRUR$) with initial $NRI = 10^{12}$ | M1 | Survey 2 |
| 2 | Per-Capita Resource Usage (PCRUM) | Nonlinear lookup / interpolation from $IOPC$ | M1 | Survey 2 |
| 3 | Capital Allocation to Resources (FCAOR) | Resource depletion drag on industrial capital | M1 | Survey 2 |
| 4 | Persistent Pollution Stock & ODE | Accumulation ODE ($dPPOL/dt = PPAPR - PPASR$) | M2 | Survey 2 |
| 5 | Pollution Transmission Delay (Delay3) | 3rd-order delay with $PPTD = 20.0$ years | M2 | Survey 2 |
| 6 | Ecosystem Assimilation Rate (PPASR) | Variable half-life assimilation model | M2 | Survey 2 |
| 7 | Age-Specific Pollution Vulnerability | `[104]f64` vector profile for infant/elderly toxicity mortality | M2 | Survey 2 |
| 8 | Arable & Urban Land Dynamics (AL, PAL, UIL) | Land expansion, urban removal, and soil erosion | M3 | Survey 2 |
| 9 | Soil Fertility & Degradation (LFERT, LFDR) | Fertility regeneration and degradation from pollution | M3 | Survey 2 |
| 10 | Agricultural Inputs & Crop Yield (AI, LY) | Capital input smoothing and agricultural yield calculation | M3 | Survey 2 |
| 11 | Capital Allocation to Agriculture (FIOAA) | Industrial capital diversion based on food ratio | M3 | Survey 2 |
| 12 | Age-Specific Food Caloric Demand | `[104]f64` vector profile for age-graded caloric demand | M3 | Survey 2 |
| 13 | Age-Specific Starvation Vulnerability | `[104]f64` vector profile for infant/elderly famine mortality | M3 | Survey 2 |
| 14 | Synchronous 5-Sector Loop Hookup | Wire Population, Economy, Resources, Agriculture, Pollution in `src/main_padded.zig` | M4 | Survey 1 |
| 15 | Composite Collision-Zone Mortality Vector | Vector multiplication of base, food, and pollution mortality into `[104]f64` | M4 | Survey 1, 2 |
| 16 | Zero-Heap Allocation Enforcement | Guarantee 0 bytes allocated during simulation loop | M4, M5 | Survey 3 |
| 17 | Sub-1,500 ns Step Benchmark Compliance | Compile with `zig build-exe -O ReleaseFast` and run in < 1,500 ns/step | M4, M5 | Survey 3 |
| 18 | Demographic Safety & Branchless Guardrails | Prevent NaN, Inf, and underflow using `@min`, `@max`, `safeDiv`, subnormal flush | M4, M5 | Survey 3 |
| 19 | Requirement-Driven E2E Test Suite (Tiers 1-4) | Comprehensive opaque-box test suite validating all features | M5 (Test Track) | Survey 1, 2, 3 |
| 20 | Adversarial Coverage Hardening (Tier 5) | White-box adversarial testing and verification | M5 | Survey 3 |

---

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | Resources Sector Engine | Implement `src/resources.zig` with `ResourceEngine`, `ResourceState`, `ResourceCurves`, unit tests | none | DONE |
| M2 | Pollution Sector Engine | Implement `src/pollution.zig` with `PollutionEngine`, `PollutionState`, `PollutionCurves`, `Delay3`, unit tests | none | DONE |
| M3 | Agriculture Sector Engine | Implement `src/agriculture.zig` with `AgricultureEngine`, `AgricultureState`, `AgricultureCurves`, unit tests | M1, M2 (contracts defined) | DONE |
| M4 | Unified 5-Sector Engine Integration | Wire all sectors synchronously into `src/main_padded.zig` with collision-zone mortality composition | M1, M2, M3 | DONE |
| M5 | Final Milestone: E2E Test Pass & Hardening | Pass 100% of E2E test suite (Tiers 1-4) and adversarial hardening (Tier 5) | M4, E2E Test Suite | IN_PROGRESS |

---

## Interface Contracts

### 1. Resources Engine (`src/resources.zig`)
```zig
pub const ResourceState = struct {
    remaining_resources: f64, // Initial: 1.0e12
    fcaor: f64,               // Fraction of capital allocated to resources
};

pub const ResourceCurves = struct {
    resource_usage_profile: [104]f64, // Per-capita usage by age
};

pub const ResourceOutput = struct {
    remaining_resources: f64,
    nrfr: f64,               // Fraction remaining [0.0, 1.0]
    fcaor: f64,              // Capital allocation fraction [0.05, 1.0]
    resource_usage_rate: f64,
    pcrum: f64,              // Per-capita resource usage multiplier
};

pub const ResourceEngine = struct {
    state: ResourceState,
    pub fn init() ResourceEngine;
    pub fn step(self: *@This(), total_pop: f64, iopc: f64, dt: f64) ResourceOutput;
};
```

### 2. Pollution Engine (`src/pollution.zig`)
```zig
pub const PollutionState = struct {
    ppol: f64,        // Persistent pollution units (Initial: 2.5e7)
    ppolx: f64,       // Index normalized to 1970 (1.36e8)
    delay_stages: [3]f64, // 3rd-order delay transmission state
};

pub const PollutionCurves = struct {
    vulnerability_profile: [104]f64, // Age-graded toxic vulnerability (infant/elderly peak)
};

pub const PollutionOutput = struct {
    ppol: f64,
    ppolx: f64,
    lmp: f64,         // Lifetime multiplier from pollution [0.2, 1.0]
};

pub const PollutionEngine = struct {
    state: PollutionState,
    pub fn init() PollutionEngine;
    pub fn step(self: *@This(), total_pop: f64, pcrum: f64, aiph: f64, arable_land: f64, dt: f64) PollutionOutput;
    pub fn calculateMortalityMultiplier(ppolx: f64, vuln_profile: *const [104]f64) [104]f64;
};
```

### 3. Agriculture Engine (`src/agriculture.zig`)
```zig
pub const AgricultureState = struct {
    arable_land: f64,     // ha (Initial: 0.9e9)
    potentially_arable: f64, // ha (Initial: 2.3e9)
    urban_land: f64,      // ha (Initial: 8.2e6)
    land_fertility: f64,  // kg/(ha-yr) (Initial: 600.0)
    agricultural_inputs: f64, // $/yr (Initial: 5.0e9)
    perceived_food_ratio: f64, // Initial: 1.0
};

pub const AgricultureCurves = struct {
    food_demand_profile: [104]f64,        // kg/person-yr (infants: 80, adults: 230)
    starvation_vulnerability: [104]f64,    // infant/elderly susceptibility
};

pub const AgricultureOutput = struct {
    food_produced: f64,    // kg/yr
    food_per_capita: f64,  // kg/person-yr
    food_ratio: f64,       // food / demand
    fioaa: f64,            // Fraction of industrial output allocated to agriculture
    arable_land: f64,
    aiph: f64,             // Agricultural inputs per hectare
};

pub const AgricultureEngine = struct {
    state: AgricultureState,
    pub fn init() AgricultureEngine;
    pub fn step(self: *@This(), total_pop: f64, industrial_output: f64, iopc: f64, ppolx: f64, total_food_demand: f64, dt: f64) AgricultureOutput;
    pub fn calculateMortalityMultiplier(food_ratio: f64, vuln_profile: *const [104]f64) [104]f64;
};
```

### 4. Economy Feedback (`src/economy.zig`)
- Industrial output modified by resource extraction drag ($FCAOR$):
  $$IO = (IC \times (1.0 - FCAOR) \times 0.13184) \times (\text{Labor} / 10^9)$$
- Net industrial output available after agricultural capital allocation ($FIOAA$):
  $$TAI = IO \times FIOAA$$

### 5. Unified Benchmark Entry (`src/main_padded.zig`)
- Single synchronous loop:
  1. Aggregate demographics (Total Pop, Labor via `[104]f64`, Food Demand via `[104]f64`)
  2. Compute Economy ($IO$ throttled by $FCAOR$)
  3. Step Resources
  4. Step Agriculture (using $IO$, $IOPC$, $PPOLX$, Food Demand)
  5. Step Pollution (using $PCRUM$, $AIPH$, $AL$)
  6. Compute Composite Mortality:
     `mort_m[i] = @min(1.0, base_mort_m[i] * food_mort[i] * poll_mort[i])`
     `mort_f[i] = @min(1.0, base_mort_f[i] * food_mort[i] * poll_mort[i])`
  7. Step Demographics: `dem.step(asfr, mort_m, mort_f)`

---

## Code Layout
```
src/
├── main_padded.zig        # Unified 5-sector benchmark entry point
├── population_padded.zig  # Demographics engine ([104]f64 arrays)
├── economy.zig            # Economy engine
├── resources.zig          # [M1] Non-Renewable Resources sector
├── pollution.zig          # [M2] Persistent Pollution sector
├── agriculture.zig        # [M3] Agriculture & Food sector
└── root.zig               # Library export declarations
tests/
├── e2e_harness.zig        # [E2E] Requirement-driven test harness
├── test_tier1_features.zig # [E2E Tier 1] Feature isolation tests
├── test_tier2_boundaries.zig # [E2E Tier 2] Boundary & corner tests
├── test_tier3_interactions.zig # [E2E Tier 3] Pairwise cross-sector tests
├── test_tier4_scenarios.zig # [E2E Tier 4] Real-world planetary collapse scenarios
└── test_tier5_adversarial.zig # [M5 Tier 5] Stress tests and adversarial hardening
```
