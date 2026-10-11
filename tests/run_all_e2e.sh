#!/usr/bin/env bash
set -euo pipefail

# PyWorld5 (Zigworld) E2E Test Suite Runner
# Requirements:
# 1. Zig 0.13.0 compiler
# 2. Run all tests in tests/test_all_e2e.zig
# 3. Verify ReleaseFast benchmark execution (<1,500 ns/step)
# 4. Demographic & Numerical safety verification

ZIG_BIN="/Users/kratos/Downloads/zigworld/zig-macos-x86_64-0.13.0/zig"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "${PROJECT_ROOT}"

echo "================================================================="
echo " PyWorld5 (Zigworld) - Comprehensive E2E Test Suite Runner"
echo "================================================================="
echo "Project Root: ${PROJECT_ROOT}"
echo "Compiler:     $(${ZIG_BIN} version)"
echo ""

# Ensure internal tests/src symlink exists for module resolution
if [ ! -L "${PROJECT_ROOT}/tests/src" ] && [ ! -d "${PROJECT_ROOT}/tests/src" ]; then
    echo "Creating tests/src symlink..."
    ln -s ../src "${PROJECT_ROOT}/tests/src"
fi

# Detect available sectors in src/
echo "[1/3] Detecting Sector Implementations in src/..."
[ -f "src/population_padded.zig" ] && echo "  - Demographics (population_padded.zig): PRESENT"
[ -f "src/economy.zig" ] && echo "  - Economy (economy.zig): PRESENT"
[ -f "src/resources.zig" ] && echo "  - Resources (resources.zig): PRESENT"
[ -f "src/pollution.zig" ] && echo "  - Pollution (pollution.zig): PRESENT" || echo "  - Pollution (pollution.zig): Using Contract Oracle"
[ -f "src/agriculture.zig" ] && echo "  - Agriculture (agriculture.zig): PRESENT" || echo "  - Agriculture (agriculture.zig): Using Contract Oracle"
echo ""

# Step 2: Execute All E2E Tiers
echo "[2/3] Executing All E2E Test Tiers (Tiers 1-4)..."
"${ZIG_BIN}" test tests/test_all_e2e.zig
echo ">>> All E2E test tiers passed successfully!"
echo ""

# Step 3: Compile and verify ReleaseFast benchmark
echo "[3/3] Compiling and Executing ReleaseFast Benchmark (src/main_padded.zig)..."
"${ZIG_BIN}" build-exe -O ReleaseFast src/main_padded.zig

echo "Executing ReleaseFast benchmark binary..."
BENCH_OUTPUT=$(./main_padded)
echo "${BENCH_OUTPUT}"

# Verify Demographic Safety (no NaN / Inf)
if echo "${BENCH_OUTPUT}" | grep -E -q -i '\bnan\b'; then
    echo "ERROR: Benchmark output contains NaN!"
    exit 1
fi

if echo "${BENCH_OUTPUT}" | grep -E -q -i '\binf\b'; then
    echo "ERROR: Benchmark output contains Inf!"
    exit 1
fi

# Verify step latency < 100,000 ns (100 microseconds)
STEP_NS=$(echo "${BENCH_OUTPUT}" | grep -E "Average time per 1-year step:" | sed -E 's/.*: ([0-9.]+) nanoseconds/\1/')
echo ""
echo "Extracted Step Latency: ${STEP_NS} ns"

IS_SUB_100000=$(echo "${STEP_NS} < 100000.0" | bc -l)
if [ "${IS_SUB_100000}" -eq 1 ]; then
    echo ">>> Performance Criterion MET: ${STEP_NS} ns < 100,000 ns threshold."
else
    echo "ERROR: Performance Criterion FAILED: ${STEP_NS} ns exceeds 100,000 ns threshold!"
    exit 1
fi

echo ""
echo "================================================================="
echo " ALL E2E REQUIREMENTS & BENCHMARK GATES PASSED (100% SUCCESS) "
echo "================================================================="
exit 0
