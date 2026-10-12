import json
import urllib.request
import urllib.error
import math

def fetch_data():
    data = {
        "industrial_capital": 59.2,
        "service_capital": 71.7,
        "atmospheric_carbon_gtc": 800.0,
        "temperature_anomaly": 0.0,
        "init_m": [39497235.0] * 104,
        "init_f": [39497235.0] * 104
    }
    
    print("Fetching World Bank Population data (SP.POP.TOTL)...")
    pop = 8215424893.0 # Fallback default
    try:
        url = "http://api.worldbank.org/v2/country/WLD/indicator/SP.POP.TOTL?format=json"
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=5) as response:
            res = json.loads(response.read())
            if res and len(res) > 1 and res[1] and res[1][0]['value'] is not None:
                pop = float(res[1][0]['value'])
                print(f"Success! Fetched global Population: {pop:,.0f}")
    except Exception as e:
        print(f"API fetch failed: {e}. Falling back to default structural values.")

    # Mathematical approximation of 2025 Global Age Pyramid
    init_m = []
    init_f = []
    total_weights = 0.0
    weights = []
    for age in range(104):
        # Piecewise/smooth curve approximating world demographics
        if age < 20:
            # Slight bulge from births, gently increasing
            w = 1.0 + (age * 0.01)
        elif age < 50:
            # Peak working age population
            w = 1.2 - ((age - 20) * 0.005)
        elif age < 75:
            # Aging demographic, steady decline
            w = 1.05 - ((age - 50) * 0.02)
        else:
            # Exponential decay in old age
            w = 0.55 * math.exp(-0.15 * (age - 75))
            
        w = max(0.001, w)
        weights.append(w)
        total_weights += w

    for age in range(104):
        # 50.4% Male, 49.6% Female globally
        cohort_pop = pop * (weights[age] / total_weights)
        init_m.append(cohort_pop * 0.504)
        init_f.append(cohort_pop * 0.496)

    data["init_m"] = init_m
    data["init_f"] = init_f

    # Calculate effective labor using the Zig gaussian curve
    total_labor = 0.0
    for age in range(104):
        cohort_pop = init_m[age] + init_f[age]
        participation = 0.0
        if 18 <= age <= 75:
            z = (age - 45.0) / 12.0
            participation = math.exp(-0.5 * z * z)
        total_labor += cohort_pop * participation
    
    total_labor_b = total_labor / 1e9

    print("Fetching World Bank GDP data (NY.GDP.MKTP.CD)...")
    try:
        url = "http://api.worldbank.org/v2/country/WLD/indicator/NY.GDP.MKTP.CD?format=json"
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=5) as response:
            res = json.loads(response.read())
            if res and len(res) > 1 and res[1] and res[1][0]['value'] is not None:
                gdp_usd = float(res[1][0]['value'])
                print(f"Success! Fetched global GDP: ${gdp_usd:,.2f}")
                industrial_gdp_t = (gdp_usd * 0.33) / 1e12
                services_gdp_t = (gdp_usd * 0.67) / 1e12
                # Reverse engineering capital using exact effective labor
                data["industrial_capital"] = industrial_gdp_t / (0.13184 * total_labor_b)
                data["service_capital"] = services_gdp_t / (0.22111 * total_labor_b)
    except Exception as e:
        print(f"API fetch failed: {e}. Falling back to default structural values.")

    output_path = "src/calibration.zig"
    
    def to_zig_array(arr):
        return ".{ " + ", ".join(repr(float(x)) for x in arr) + " }"
        
    zig_code = f"""pub const CalibrationData = struct {{
    industrial_capital: f64,
    service_capital: f64,
    atmospheric_carbon_gtc: f64,
    temperature_anomaly: f64,
    init_m: [104]f64,
    init_f: [104]f64,
}};

pub const calib = CalibrationData{{
    .industrial_capital = {repr(float(data['industrial_capital']))},
    .service_capital = {repr(float(data['service_capital']))},
    .atmospheric_carbon_gtc = {repr(float(data['atmospheric_carbon_gtc']))},
    .temperature_anomaly = {repr(float(data['temperature_anomaly']))},
    .init_m = {to_zig_array(data['init_m'])},
    .init_f = {to_zig_array(data['init_f'])},
}};
"""
    with open(output_path, "w") as f:
        f.write(zig_code)
    print(f"Successfully wrote calibration data to {output_path}")

if __name__ == "__main__":
    fetch_data()
