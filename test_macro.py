def run():
    x = 0.01 # 1% initial positive output gap shock
    pi = 0.02
    r_n = 0.02
    pi_star = 0.02
    phi_pi = 1.5
    phi_x = 0.5
    alpha = 0.5 # IS sensitivity
    kappa = 0.1 # Phillips curve sensitivity

    for t in range(50):
        # Taylor rule
        i = r_n + pi_star + phi_pi * (pi - pi_star) + phi_x * x
        i = max(0.0, i)

        # IS curve
        real_rate = i - pi
        x_next = x - alpha * (real_rate - r_n)

        # Phillips curve
        pi_next = pi + kappa * x

        x = x_next
        pi = pi_next
        print(f"t={t}: x={x:.4f}, pi={pi:.4f}, i={i:.4f}")
run()
