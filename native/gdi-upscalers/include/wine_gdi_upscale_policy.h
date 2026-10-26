/* SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef WINE_GDI_UPSCALE_POLICY_H
#define WINE_GDI_UPSCALE_POLICY_H

#define WGDI_STABLE_SECONDS 0.250
struct wgdi_stability
{
    double changed_at;
    int observed;
};

/* Monotonic seconds and exact frame/geometry changes determine readiness.
 * A changed frame always starts a new quiet interval. */
static inline double wgdi_stability_observe(struct wgdi_stability *state, int changed, double now)
{
    double remaining;
    if (changed || !state->observed || now < state->changed_at)
    {
        state->changed_at = now;
        state->observed = 1;
    }
    remaining = WGDI_STABLE_SECONDS - (now - state->changed_at);
    return remaining > 0 ? remaining : 0;
}
#endif
