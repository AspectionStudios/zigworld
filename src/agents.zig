const std = @import("std");

pub const NUM_HOUSEHOLDS = 10_000_000;
const V_LEN = 16;
const Vec = @Vector(V_LEN, f32);

extern "C" fn run_agents_metal(x_pos: [*]f32, y_pos: [*]f32, vuln: [*]f32, temp_anomaly: f32, count: i32) void;

pub const AgentSystem = struct {
    age: [NUM_HOUSEHOLDS]f32 align(64),
    employed: [NUM_HOUSEHOLDS]f32 align(64), // 1.0 for true, 0.0 for false
    energy_consumed: [NUM_HOUSEHOLDS]f32 align(64),
    savings: [NUM_HOUSEHOLDS]f32 align(64),
    vulnerability: [NUM_HOUSEHOLDS]f32 align(64),
    x_pos: [NUM_HOUSEHOLDS]f32 align(64),
    y_pos: [NUM_HOUSEHOLDS]f32 align(64),

    pub fn initHeap() !*AgentSystem {
        var system = try std.heap.page_allocator.create(AgentSystem);
        system.reset();
        return system;
    }

    pub fn init() AgentSystem {
        var system: AgentSystem = undefined;
        system.reset();
        return system;
    }

    pub fn reset(self: *@This()) void {
        @memset(&self.age, 30.0);
        @memset(&self.employed, 1.0);
        @memset(&self.energy_consumed, 0.0);
        @memset(&self.savings, 100.0);
        @memset(&self.vulnerability, 0.0);
        @memset(&self.x_pos, 0.0);
        @memset(&self.y_pos, 0.0);
        
        for (0..NUM_HOUSEHOLDS) |i| {
            self.vulnerability[i] = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(NUM_HOUSEHOLDS));
            self.age[i] = @as(f32, @floatFromInt(i % 80)) + 18.0;
            self.x_pos[i] = @as(f32, @floatFromInt(i % 100));
            self.y_pos[i] = @as(f32, @floatFromInt((i / 100) % 100));
        }
    }

    pub fn OLD_init() AgentSystem {
        var system = AgentSystem{
            .age = [_]f32{30.0} ** NUM_HOUSEHOLDS,
            .employed = [_]f32{1.0} ** NUM_HOUSEHOLDS,
            .energy_consumed = [_]f32{0.0} ** NUM_HOUSEHOLDS,
            .savings = [_]f32{100.0} ** NUM_HOUSEHOLDS,
            .vulnerability = [_]f32{0.0} ** NUM_HOUSEHOLDS,
            .x_pos = [_]f32{0.0} ** NUM_HOUSEHOLDS,
            .y_pos = [_]f32{0.0} ** NUM_HOUSEHOLDS,
        };
        
        for (0..NUM_HOUSEHOLDS) |i| {
            system.vulnerability[i] = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(NUM_HOUSEHOLDS));
            system.age[i] = @as(f32, @floatFromInt(i % 80)) + 18.0;
            // Distribute on 100x100 grid
            system.x_pos[i] = @as(f32, @floatFromInt(i % 100));
            system.y_pos[i] = @as(f32, @floatFromInt((i / 100) % 100));
        }
        return system;
    }

    pub inline fn step(self: *@This(), unemployment_multiplier: f64, base_energy_per_capita: f64, temperature_anomaly: f64) struct { total_energy: f64, total_savings: f64 } {
        const u_mult_splat: Vec = @splat(@as(f32, @floatCast(unemployment_multiplier)));
        const emp_e: Vec = @splat(@as(f32, @floatCast(base_energy_per_capita * 1.2)));
        const unemp_e: Vec = @splat(@as(f32, @floatCast(base_energy_per_capita * 0.8)));
        const temp_splat: Vec = @splat(@as(f32, @floatCast(temperature_anomaly)));
        const savings_add: Vec = @splat(10.0);
        const savings_sub: Vec = @splat(5.0);
        const zero: Vec = @splat(0.0);
        const one: Vec = @splat(1.0);
                const old_age: Vec = @splat(100.0);
        const reset_age: Vec = @splat(18.0);
        const half: Vec = @splat(0.5);
        
        const fifty: Vec = @splat(50.0);
                        const temp_vul_weight: Vec = @splat(0.1); // Weight of temperature on vulnerability

        run_agents_metal(@ptrCast(&self.x_pos), @ptrCast(&self.y_pos), @ptrCast(&self.vulnerability), @as(f32, @floatCast(temperature_anomaly)), NUM_HOUSEHOLDS);
        var total_energy_sum: f64 = 0.0;
        var total_savings_sum: f64 = 0.0;

        // Process in chunks of V_LEN
        var i: usize = 0;
        while (i < NUM_HOUSEHOLDS) : (i += V_LEN) {
            const vul: Vec = self.vulnerability[i..][0..V_LEN].*;
            var age_vec: Vec = self.age[i..][0..V_LEN].*;
            var sav_vec: Vec = self.savings[i..][0..V_LEN].*;
            const y_vec: Vec = self.y_pos[i..][0..V_LEN].*;

            // Climate Zone calculation (0=pole, 50=equator, 100=pole)
            const y_gt_50 = y_vec > fifty;
            const dist_eq = @select(f32, y_gt_50, y_vec - fifty, fifty - y_vec);
            const norm_dist = dist_eq / fifty;
            
            // Local temperature damage (higher closer to equator)
            const local_temp = temp_splat * (one - norm_dist);

            // Economic viability (vulnerability + local temp impact)
            const effective_vul = vul + (local_temp * temp_vul_weight);

            // Employment status
            const is_employed_bool = effective_vul < u_mult_splat;
            const emp_f32: Vec = @select(f32, is_employed_bool, one, zero);
            const unemp_f32: Vec = one - emp_f32;
            self.employed[i..][0..V_LEN].* = emp_f32;

            // Energy consumed
            const e_cons = (emp_f32 * emp_e) + (unemp_f32 * unemp_e);
            self.energy_consumed[i..][0..V_LEN].* = e_cons;

            // Update savings
            sav_vec = @max(zero, sav_vec + (emp_f32 * savings_add) - (unemp_f32 * savings_sub));

            // Aging
            const is_old_bool = age_vec >= old_age;
            const old_f32: Vec = @select(f32, is_old_bool, one, zero);
            const not_old_f32: Vec = one - old_f32;

            age_vec = @select(f32, is_old_bool, reset_age, age_vec + one);
            self.age[i..][0..V_LEN].* = age_vec;
            
            // Inheritance / reset
            const mult: Vec = not_old_f32 + (old_f32 * half);
            sav_vec = sav_vec * mult;
            self.savings[i..][0..V_LEN].* = sav_vec;
            
            // Accumulate sums safely in f64
            total_energy_sum += @as(f64, @floatCast(@reduce(.Add, e_cons)));
            total_savings_sum += @as(f64, @floatCast(@reduce(.Add, sav_vec)));
        }
        
        return .{
            .total_energy = total_energy_sum,
            .total_savings = total_savings_sum,
        };
    }
};
