# Round 3 evidence — `-mcpu=cortex-a76` test on the two ARMv8.2 chips

Recorded 2026-04-29. Hypothesis: the -12 % p50 regression observed in
round 1 dispatched on Huawei Y9a (FRL-L23, Helio G80, Cortex-A75) was
caused by the `-mcpu=cortex-a78` value of `libdazzle_v82.so` issuing
OoO speculation the A75 retire-port could not sustain. We recompiled
`libdazzle_v82.so` with `-mcpu=cortex-a76` (one pipeline generation
ahead of A75 instead of three) and re-ran `vector-bench-paper384-scale`
in dispatched mode (no `force_native_variant` override) on both the
Helio G80 unit and the Unisoc T760 reference unit.

| Chip                       | dazzle_sq8 N=20k p50, by build                |
|----------------------------|-----------------------------------------------|
|                            | baseline `-mcpu=generic` (libdazzle.so)       |
|                            | v82 round 1 `-mcpu=cortex-a78` (round-1 dispatched JSON) |
|                            | **v82 round 3 `-mcpu=cortex-a76` (this folder)**           |
| G35 5G  (Unisoc T760, A76) | 269 µs / 269 µs / **280 µs**                  |
| FRL-L23 (Helio G80, A75)   | 588 µs / 671 µs / **680 µs**                  |

Findings:

  1. **Helio G80 (Cortex-A75)**: cortex-a76 (671 → 680 µs) reproduced
     the regression to within run-to-run noise. The -mcpu retune did
     NOT eliminate the -12 % gap vs baseline.
  2. **Unisoc T760 (Cortex-A76, exact match for the new mcpu)**:
     cortex-a76 (269 → 280 µs) was 4 % SLOWER than cortex-a78,
     within thermal-/load-induced noise. The native scheduler model
     for the T760's big core did not improve perf.

Conclusion: `-mcpu` (scheduler tuning) is not on the critical path
of the regression. We reverted CMakeLists.txt to `-mcpu=cortex-a78`
(slightly better on the T760 reference device) and ship the
`force_native_variant=baseline` override as the recommended
mitigation for chips with known-A75 big cores. See paper §6.3 for
the full discussion.

These JSONs are raw experimental evidence; they are NOT the canonical
round 1 dispatched cells (those live at
`../dispatched/vecbench_moto_g35_5G_1777436296256.json` and
`../dispatched/vecbench_FRL-L23_1777436701814.json`, both cortex-a78).
