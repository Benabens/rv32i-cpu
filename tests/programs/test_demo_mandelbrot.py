"""Tests for programs/demo/mandelbrot.s (ASCII Mandelbrot set, Q22.10).

The reference below recomputes the picture in Python with ordinary integer
multiplication: it shares nothing with the assembly program (which multiplies
with a table of quarter squares) except the documented arithmetic: Q22.10
values, products truncated toward zero, at most 32 iterations.
"""

import random
import unittest

from tests.programs.harness import Machine, run_program, to_s32, to_u32

PATH = "programs/demo/mandelbrot.s"
FRAC = 10
ONE = 1 << FRAC
WIDTH, HEIGHT = 78, 33
X0, DX, DY = -2150, 37, 74          # -2.1, 37/1024, 74/1024
MAX_ITER = 32
SHADES = "  .:-==++***#####%%%%%%%%%%%%%%%@"
TITLE = "Mandelbrot set on RV32I -- Q22.10 fixed point, no multiplier, 32 iterations max\n"
FOOTER = "iterations of z = z^2 + c computed: "
FOOTER2 = " (lower half mirrored)\n"


def fx_mul(a, b):
    """Q22.10 product, truncated toward zero (explicitly, on the magnitude)."""
    magnitude = (abs(a) * abs(b)) >> FRAC
    return -magnitude if (a < 0) != (b < 0) else magnitude


def escape_time(cx, cy):
    x = y = 0
    for n in range(MAX_ITER):
        x2, y2 = fx_mul(x, x), fx_mul(y, y)
        if x2 + y2 > 4 * ONE:
            return n
        x, y = x2 - y2 + cx, 2 * fx_mul(x, y) + cy
    return MAX_ITER


def reference():
    """(expected output, list of picture rows, iterations computed).

    Every row is computed here, including the lower half that the program
    only mirrors; the iteration count covers rows 0..16, as in the program.
    """
    rows, total = [], 0
    for row in range(HEIGHT):
        cy = (row - HEIGHT // 2) * DY
        line = []
        for col in range(WIDTH):
            n = escape_time(X0 + col * DX, cy)
            if row <= HEIGHT // 2:
                total += n
            line.append(SHADES[n])
        rows.append("".join(line))
    text = TITLE + "".join(r + "\n" for r in rows) + FOOTER + f"{total}" + FOOTER2
    return text, rows, total


class MandelbrotTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cpu = run_program(PATH, max_steps=1_000_000)
        cls.expected, cls.rows, cls.total = reference()

    def test_exits_cleanly_within_budget(self):
        self.assertEqual(self.cpu.exit_code, 0)
        self.assertLess(self.cpu.steps, 1_000_000)

    def test_output_matches_reference(self):
        self.assertEqual(self.cpu.output, self.expected)

    def test_picture_dimensions(self):
        lines = self.cpu.output.split("\n")
        picture = lines[1:1 + HEIGHT]
        self.assertEqual(len(picture), HEIGHT)
        self.assertTrue(all(len(line) == WIDTH for line in picture))
        self.assertTrue(lines[1 + HEIGHT].startswith(FOOTER))

    def test_symmetric_about_real_axis(self):
        picture = self.cpu.output.split("\n")[1:1 + HEIGHT]
        for i in range(HEIGHT):
            self.assertEqual(picture[i], picture[HEIGHT - 1 - i], f"rows {i} and {HEIGHT - 1 - i}")

    def test_picture_is_recognisable(self):
        picture = self.cpu.output.split("\n")[1:1 + HEIGHT]
        axis = picture[HEIGHT // 2]

        def col(x):
            return round((x * ONE - X0) / DX)
        # Known members of M on the real axis: -1 (period-2 bulb centre), 0
        # (cardioid centre), -1.75 (period-3 window), 0.25 (the cusp).
        for x in (-1.75, -1.0, -0.5, 0.0, 0.2):
            self.assertEqual(axis[col(x)], "@", x)
        # |c| > 2 escapes immediately: blank. 0.5 is outside, escapes slowly.
        self.assertEqual(axis[0], " ")
        self.assertNotEqual(axis[col(0.5)], "@")
        # The top and bottom rows (|y| = 1.16) contain no member of M.
        self.assertNotIn("@", picture[0])
        self.assertGreater(sum(line.count("@") for line in picture), 300)

    def test_footer_total(self):
        self.assertTrue(self.cpu.output.endswith(f"{FOOTER}{self.total}{FOOTER2}"))


class FixedPointRoutinesTest(unittest.TestCase):
    """build_squares / fxmul / mandel called directly, against plain integers."""

    @classmethod
    def setUpClass(cls):
        cls.m = Machine(PATH)
        cls.m.call("build_squares", max_steps=200_000)

    def test_square_table(self):
        for n in list(range(0, 50)) + [1000, 2047, 4095, 4096]:
            self.assertEqual(self.m.cpu.load_word(0x10001000 + 4 * n), n * n // 4, n)

    def test_squares_through_fxmul(self):
        rng = random.Random(1)
        values = [0, 1, -1, ONE, -ONE, 2 * ONE, -2 * ONE] + \
                 [rng.randint(-2 * ONE, 2 * ONE) for _ in range(300)]
        for a in values:
            self.assertEqual(to_s32(self.m.call("fxmul", to_u32(a), to_u32(a))), fx_mul(a, a), a)

    def test_fxmul(self):
        rng = random.Random(2)
        pairs = [(3 * ONE // 2, -ONE), (-1, 1), (-1, -1), (-ONE, -ONE), (0, -5),
                 (-1500, 1400), (1500, -1400), (2896, 0)]
        for _ in range(400):
            a = rng.randint(-2 * ONE, 2 * ONE)     # |a| + |b| <= 4096: the
            b = rng.randint(-2 * ONE, 2 * ONE)     # documented table range
            pairs.append((a, b))
        for a, b in pairs:
            got = to_s32(self.m.call("fxmul", to_u32(a), to_u32(b)))
            self.assertEqual(got, fx_mul(a, b), (a, b))
            # truncation toward zero makes the product an odd function
            self.assertEqual(to_s32(self.m.call("fxmul", to_u32(-a), to_u32(b))), -got)

    def test_mandel_points(self):
        cases = [(0, 0), (-ONE, 0), (2 * ONE, 0), (-2150, -1184), (300, 500),
                 (-768, 100), (256, 0), (-1792, 0)]
        for cx, cy in cases:
            self.assertEqual(self.m.call("mandel", to_u32(cx), to_u32(cy)),
                             escape_time(cx, cy), (cx, cy))


if __name__ == "__main__":
    unittest.main()
