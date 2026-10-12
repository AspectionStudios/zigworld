#include <metal_stdlib>
using namespace metal;

kernel void updateAgents(
    device float* x_pos [[ buffer(0) ]],
    device float* y_pos [[ buffer(1) ]],
    device const float* vulnerability [[ buffer(2) ]],
    constant float& temp_anomaly [[ buffer(3) ]],
    uint id [[ thread_position_in_grid ]]
) {
    if (id >= 10000) return;
    
    float y = y_pos[id];
    float x = x_pos[id];
    float vul = vulnerability[id];
    
    // Equator is at Y=50
    bool y_gt_50 = y > 50.0;
    float dist_eq = y_gt_50 ? (y - 50.0) : (50.0 - y);
    float norm_dist = dist_eq / 50.0;
    
    // Migration is stronger closer to equator (where it is hotter)
    float local_temp = temp_anomaly * (1.0 - norm_dist);
    
    float mig_rate = 2.0;
    float migration_step = local_temp * mig_rate; 
    float direction = y_gt_50 ? 1.0 : -1.0;
    
    // Slide along Y axis toward poles
    y += direction * migration_step;
    y = max(0.0, min(100.0, y));
    y_pos[id] = y;
    
    // X drift is strictly dependent on vulnerability to spread agents safely
    float x_drift = (vul - 0.5) * mig_rate;
    x += x_drift;
    x = max(0.0, min(100.0, x));
    x_pos[id] = x;
}
