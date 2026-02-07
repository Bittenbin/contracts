# Tenbin Puzzle: Isosceles Shift

## Puzzle
You are trading on a market currently at lattice point (x, y) with x > 0 and y > 0.
Let c be the current hypotenuse, so:

  x^2 + y^2 = c^2

You may move the market to a new lattice point by increasing exactly one coordinate:

  - (x, y') where y' > y, or
  - (x', y) where x' > x

Subject to the following conditions:

1) The delta must equal the old hypotenuse:
   - x' - x = c  OR  y' - y = c

2) The old hypotenuse must be a positive integer:
   - x^2 + y^2 = c^2

3) Directional constraint:
   - If moving y to y', then y > x
   - If moving x to x', then x > y

4) Multiplicity constraint:
   - If moving y to y', then y' must be a multiple of y
   - If moving x to x', then x' must be a multiple of x

Find all integer solutions (x, y, c, x', y') that satisfy the rules.

If you can provide a valid move, you earn the Tenbin Dollar reward.

---

## Solution
We show that no nontrivial solution exists under the stated rules.

Start with a Pythagorean triple:

  x^2 + y^2 = c^2,  x > 0, y > 0, c > 0

If we move along y, the multiplicity constraint says:

  y' = y + c  and  y | y'  ->  y | c

If we move along x, it says:

  x' = x + c  and  x | x'  ->  x | c

So any valid move requires that the moved leg divides the hypotenuse.

Write the triple as a scalar multiple of a primitive triple:

  x = kx0,  y = ky0,  c = kc0

with gcd(x0, y0) = 1 and gcd(x0, c0) = gcd(y0, c0) = 1.

If x divides c, then:

  kx0 | kc0  ->  x0 | c0

But gcd(x0, c0) = 1, so the only way x0 | c0 is x0 = 1.
A primitive triple cannot have a leg equal to 1:

  1^2 + y0^2 = c0^2  ->  (c0 - y0)(c0 + y0) = 1

which forces y0 = 0, not allowed.
Therefore x0 ≠ 1, so x0 ∤ c0 and x ∤ c.

The same argument holds for y dividing c.

Conclusion:

No Pythagorean triple with positive legs satisfies the divisibility rule,
so no valid move exists under these added constraints.
