import math
for alpha in [0.1, 0.5, 1.0]:
    for kappa in [0.05, 0.2, 0.5]:
        for phi_x in [0.0, 0.5]:
            x = 0.05
            pi = 0.02
            cycles = 0
            prev_x = x
            for t in range(50):
                i = 0.02 + 0.02 + 1.5*(pi-0.02) + phi_x*x
                i = max(0, i)
                x_next = x - alpha*(i - pi - 0.02)
                pi_next = pi + kappa*x_next
                if (x_next > 0 and prev_x < 0) or (x_next < 0 and prev_x > 0):
                    cycles += 1
                prev_x = x
                x = x_next
                pi = pi_next
            if cycles > 2:
                print(f"alpha={alpha}, kappa={kappa}, phi_x={phi_x} gives {cycles} crossings, final x={x:.4f}")
