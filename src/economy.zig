const std = @import("std");

pub const EconomyState = struct {
    industrial_capital: f64,
    service_capital: f64,
};

pub const EconomyCurves = struct {
    labor_participation: [104]f64,
    energy_demand_profile: [104]f64,
};

pub const EconomyEngine = struct {
    state: EconomyState,

    pub fn step(self: *@This(), males: *const [104]f64, females: *const [104]f64, curves: *const EconomyCurves) struct {
        industrial_output: f64,
        services_output: f64,
        energy_twh: f64,
    } {
        var total_labor: f64 = 0;
        var total_energy: f64 = 0;

        for (0..104) |age| {
            const cohort_pop = males[age] + females[age];
            total_labor += cohort_pop * curves.labor_participation[age];
            total_energy += cohort_pop * curves.energy_demand_profile[age];
        }

        // Apply labor to capital to get real-world calibrated outputs
        // (Dividing by 1 billion to scale labor to billions of workers)
        // With 8B pop distributed evenly, the Gaussian labor curve integral yields ~2.27B effective full-time workers.
        // 2.275B * 105T capital * 0.13184 = $31.5T Industrial
        // 2.275B * 128T capital * 0.22111 = $64.4T Services
        const industrial_output = (self.state.industrial_capital * 0.13184) * (total_labor / 1_000_000_000.0);
        const services_output = (self.state.service_capital * 0.22111) * (total_labor / 1_000_000_000.0);

        return .{
            .industrial_output = industrial_output,
            .services_output = services_output,
            .energy_twh = total_energy,
        };
    }
};

pub fn generateDefaultCurves() EconomyCurves {
    var curves = EconomyCurves{
        .labor_participation = [_]f64{0.0} ** 104,
        .energy_demand_profile = [_]f64{0.0} ** 104,
    };
    
    for (0..104) |age| {
        const a: f64 = @floatFromInt(age);
        
        // 1. Labor Participation Curve (Gaussian bell curve peaking at age 45)
        if (age >= 18 and age <= 75) {
            const z = (a - 45.0) / 12.0;
            curves.labor_participation[age] = std.math.exp(-0.5 * z * z);
        }
        
        // 2. Energy Demand Profile (TWh per individual)
        if (age < 15) {
            curves.energy_demand_profile[age] = 0.5 * (a / 15.0);
        } else if (age <= 80) {
            curves.energy_demand_profile[age] = 1.0;
        } else {
            const drop = (a - 80.0) / 24.0;
            curves.energy_demand_profile[age] = @max(0.5, 1.0 - (drop * 0.5));
        }
        
        // Scale energy demand to hit the Tribunal's ~116,600 TWh when applied to 8 billion people
        // True multiplier based on the integral of the profile is ~17.473 TWh per 1M people
        curves.energy_demand_profile[age] *= (17.473 / 1_000_000.0);
    }
    
    return curves;
}
