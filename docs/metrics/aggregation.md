# Aggregation & Statistics

Each protocol/scenario combination is executed across 10 identical repetitions ($R_1 \dots R_{10}$) to measure variance and guarantee statistical validity.

## Mathematical Formulation

The aggregation script groups rows in `results/summary.csv` by `(protocol, scenario)` and calculates sample parameters across valid observations $v_1, \dots, v_c$:

### 1. Arithmetic Mean ($\mu$)
$$\mu = \frac{1}{c}\sum_{i=1}^{c} v_i$$

### 2. Sample Variance ($s^2$)
Calculated using Bessel's correction ($c-1$ denominator) for an unbiased estimate:
$$s^2 = \frac{\sum_{i=1}^{c} v_i^2 - c \cdot \mu^2}{c - 1}$$

### 3. Sample Standard Deviation ($s$)
$$s = \sqrt{\max(s^2, 0)}$$
*(If $c \le 1$, standard deviation is defined as 0.0).*

## Missing Data Handling

If a server scrape gap occurs (e.g. transient timeout returning `NaN`), the parser omits that sample point from the calculation. It does **not** coerce missing entries to 0, ensuring averages are not artificially deflated.
