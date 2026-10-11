const std = @import("std");

/// The state of the population sector.
pub const PopulationState = struct {
    /// Male population array, indices 0 through 103. Index 103 represents 103+ years old.
    males: [104]f64,
    /// Female population array, indices 0 through 103. Index 103 represents 103+ years old.
    females: [104]f64,

    total_pop: f64,
    births: f64,
    deaths: f64,
};

pub const Demographics = struct {
    state: PopulationState,

    pub fn init() Demographics {
        return Demographics{
            .state = .{
                .males = [_]f64{0} ** 104,
                .females = [_]f64{0} ** 104,
                .total_pop = 0,
                .births = 0,
                .deaths = 0,
            },
        };
    }

    /// Set an initial population uniformly for testing, or from real data.
    pub fn loadInitialData(self: *Demographics, m_pop: [104]f64, f_pop: [104]f64) void {
        self.state.males = m_pop;
        self.state.females = f_pop;
        var total: f64 = 0;
        for (self.state.males) |p| total += p;
        for (self.state.females) |p| total += p;
        self.state.total_pop = total;
    }

    /// Step the population forward by 1 year (dt = 1.0).
    /// With single-year cohorts, a dt of 1.0 is structurally elegant.
    /// asfr: Age-Specific Fertility Rate (births per female per year)
    /// mortality_m: Mortality rate for males at that age
    /// mortality_f: Mortality rate for females at that age
    pub fn step(self: *Demographics, asfr: [104]f64, mortality_m: [104]f64, mortality_f: [104]f64) void {
        var next_males = [_]f64{0} ** 104;
        var next_females = [_]f64{0} ** 104;

        var total_births: f64 = 0;
        var total_deaths: f64 = 0;
        var total_pop: f64 = 0;

        // 1. Calculate Births (Age-Specific Fertility Rate applied to females)
        // Typically only females aged 15-49 have an ASFR > 0.
        for (self.state.females, 0..) |f_pop, age| {
            total_births += f_pop * asfr[age];
        }

        // Assuming the biological standard 1.05 male-to-female sex ratio at birth.
        const male_births = total_births * (1.05 / 2.05);
        const female_births = total_births * (1.00 / 2.05);

        // 2. Age the population and apply mortality
        
        // Age 0: New births minus infant mortality
        const m0_deaths = male_births * mortality_m[0];
        const f0_deaths = female_births * mortality_f[0];
        total_deaths += m0_deaths + f0_deaths;
        
        next_males[0] = male_births - m0_deaths;
        next_females[0] = female_births - f0_deaths;

        // Ages 1 to 99
        for (0..103) |age| {
            const m_pop = self.state.males[age];
            const f_pop = self.state.females[age];
            
            const m_deaths = m_pop * mortality_m[age + 1];
            const f_deaths = f_pop * mortality_f[age + 1];
            total_deaths += m_deaths + f_deaths;

            // They age up by 1 year (age -> age + 1)
            next_males[age + 1] = m_pop - m_deaths;
            next_females[age + 1] = f_pop - f_deaths;
        }

        // Age 103+ (Accumulator for the final cohort)
        // Those who were already 103+ survive to be 103+ again, minus their mortality.
        const m103_pop = self.state.males[103];
        const f103_pop = self.state.females[103];
        
        const m103_deaths = m103_pop * mortality_m[103];
        const f103_deaths = f103_pop * mortality_f[103];
        total_deaths += m103_deaths + f103_deaths;

        next_males[103] += m103_pop - m103_deaths;
        next_females[103] += f103_pop - f103_deaths;

        // 3. Commit state
        self.state.males = next_males;
        self.state.females = next_females;
        self.state.births = total_births;
        self.state.deaths = total_deaths;

        // Sum up total population
        for (self.state.males) |p| total_pop += p;
        for (self.state.females) |p| total_pop += p;
        self.state.total_pop = total_pop;
    }
};

test "conservation check" {
    var dem = Demographics.init();
    
    // Seed with 1 million men and 1 million women aged 20
    var init_m = [_]f64{0} ** 104;
    var init_f = [_]f64{0} ** 104;
    init_m[20] = 1_000_000;
    init_f[20] = 1_000_000;
    dem.loadInitialData(init_m, init_f);

    const initial_pop = dem.state.total_pop;

    var asfr = [_]f64{0} ** 104;
    asfr[20] = 0.1; // 10% birth rate for 20 yr old females
    
    const mort_m = [_]f64{0.01} ** 104; // 1% mortality
    const mort_f = [_]f64{0.01} ** 104; // 1% mortality

    dem.step(asfr, mort_m, mort_f);

    const expected_pop = initial_pop + dem.state.births - dem.state.deaths;
    
    // Use floating point epsilon comparison
    try std.testing.expectApproxEqAbs(expected_pop, dem.state.total_pop, 0.0001);
}
