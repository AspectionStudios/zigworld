const std = @import("std");

pub const FinanceState = struct {
    inflation: f64,
    interest_rate: f64,
    output_gap: f64,
};

pub const FinanceCurves = struct {
    // Hardware-aligned unemployment vulnerability profile
    unemployment_vulnerability: [104]f64 align(64),
};

pub const FinanceEngine = struct {
    state: FinanceState,

    // Base parameters for 3-Equation Model (New Keynesian)
    const r_n: f64 = 0.02; // Natural rate of interest (2%)
    const pi_star: f64 = 0.02; // Target inflation (2%)
    const phi_pi: f64 = 1.5; // Taylor rule inflation response
    const phi_x: f64 = 0.0; // Taylor rule output gap response (0 to increase cycling)
    
    // Model sensitivities chosen to produce boom-bust cycles
    const alpha_x: f64 = 1.0; // IS curve sensitivity
    const kappa: f64 = 0.2; // Phillips curve sensitivity

    pub fn init() FinanceEngine {
        return .{
            .state = .{
                .inflation = 0.02,
                .interest_rate = 0.04,
                // Initial animal spirits shock to kickstart business cycles
                .output_gap = 0.05,
            },
        };
    }

    // Advance macro model by one year
    pub fn step(self: *@This()) struct {
        unemployment_multiplier: f64,
    } {
        // 1. Taylor Rule: Central bank sets nominal interest rate based on current inflation and output gap
        self.state.interest_rate = r_n + pi_star + phi_pi * (self.state.inflation - pi_star) + phi_x * self.state.output_gap;
        
        // Zero Lower Bound (ZLB)
        if (self.state.interest_rate < 0.0) {
            self.state.interest_rate = 0.0;
        }

        // 2. IS Curve: Output gap depends on real interest rate vs natural rate
        const real_rate = self.state.interest_rate - self.state.inflation;
        self.state.output_gap = self.state.output_gap - alpha_x * (real_rate - r_n);
        
        // Clamp output_gap to physical limits (e.g. -80% depression to +50% overheating)
        self.state.output_gap = @max(-0.8, @min(0.5, self.state.output_gap));
        
        // 3. Phillips Curve: Inflation driven by output gap
        self.state.inflation = self.state.inflation + kappa * self.state.output_gap;
        
        // Clamp inflation to prevent infinite deflationary spirals (ZLB trap) or hyperinflation overflow
        self.state.inflation = @max(-0.2, @min(50.0, self.state.inflation));

        // Okun's Law: Output gap inversely drives unemployment.
        // Base unemployment multiplier = 1.0. 
        // If output_gap is -0.1 (10% recession), multiplier is 0.9.
        const okun_coef: f64 = 1.0; 
        const base_multiplier = 1.0 + okun_coef * self.state.output_gap;
        
        // Clamp multiplier to sane limits [0.5, 1.2]
        const unemployment_multiplier = @max(0.5, @min(1.2, base_multiplier));

        return .{
            .unemployment_multiplier = unemployment_multiplier,
        };
    }
};

pub fn generateDefaultCurves() FinanceCurves {
    var curves = FinanceCurves{
        .unemployment_vulnerability = [_]f64{1.0} ** 104,
    };
    
    for (0..104) |age| {
        if (age < 25) {
            curves.unemployment_vulnerability[age] = 1.5; // Youth hit 50% harder by recession
        } else if (age > 55) {
            curves.unemployment_vulnerability[age] = 1.2; // Older workers hit 20% harder
        } else {
            curves.unemployment_vulnerability[age] = 1.0;
        }
    }
    
    return curves;
}
