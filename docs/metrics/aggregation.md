# Aggregation & Statistics

Each protocol/scenario combination is executed across 10 identical repetitions (R1 to R10) to measure variance and guarantee statistical validity.

## Mathematical Formulation

The aggregation script groups rows in `results/summary.csv` by `(protocol, scenario)` and calculates sample parameters across valid observations `v_1, ..., v_c`:

### 1. Arithmetic Mean (μ)

```text
μ = (1 / c) * Σ(v_i)
```

Where:
- `c`: Count of valid (non-NaN) sample observations across the 10 repetitions.
- `v_i`: Metric value recorded for repetition `i`.

### 2. Sample Variance (s²)

Calculated using Bessel's correction (`c - 1` denominator) for an unbiased estimate:

```text
s² = [ Σ(v_i²) - c · μ² ] / (c - 1)
```

*(Note: Clamped to 0 if floating-point rounding yields an infinitesimal negative value).*

### 3. Sample Standard Deviation (s)

```text
s = √( max(s², 0) )
```

*(If valid sample count `c ≤ 1`, standard deviation is defined as 0.0).*

## Missing Data Handling

If a server scrape gap occurs (e.g. transient timeout returning `NaN`), the parser omits that sample point from the calculation. It does **not** coerce missing entries to 0, ensuring averages are not artificially deflated.
