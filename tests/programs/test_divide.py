"""Tests for programs/arith/divide.s (unsigned restoring division)."""

import random
import unittest

from tests.programs.harness import Machine, run_program, to_s32, to_u32

PATH = "programs/arith/divide.s"
MASK = 0xFFFFFFFF


def edge_values():
    values = {0, 1, 2, 3, MASK, MASK - 1, 0x7FFFFFFF, 0x80000000, 0x80000001,
              0x55555555, 0xAAAAAAAA, 0x33333333, 0xCCCCCCCC, 0x0F0F0F0F,
              0xF0F0F0F0, 0x00FF00FF, 0xFF00FF00, 0x0000FFFF, 0xFFFF0000,
              0x12345678, 0xDEADBEEF}
    for k in range(32):
        values |= {1 << k, (1 << k) - 1, MASK ^ (1 << k)}
    return sorted(values)


# Smaller set for operations with two operands (all pairs are tested).
PAIR_EDGES = [0, 1, 2, 3, 7, MASK, MASK - 1, 0x7FFFFFFF, 0x7FFFFFFE, 0x80000000,
              0x80000001, 0x55555555, 0xAAAAAAAA, 0x0000FFFF, 0x00010000, 0xFFFF0000,
              0x12345678, 0xDEADBEEF]


def random_values(seed, n=300):
    rng = random.Random(seed)
    return [rng.getrandbits(32) for _ in range(n)]


def random_pairs(seed, n=300):
    rng = random.Random(seed)
    pairs = []
    for i in range(n):
        if i % 3 == 0:  # mix in small magnitudes, where bugs are easiest to read
            pairs.append((to_u32(rng.randint(-1000, 1000)), to_u32(rng.randint(-1000, 1000))))
        else:
            pairs.append((rng.getrandbits(32), rng.getrandbits(32)))
    return pairs


def reference(n, d):
    n, d = to_u32(n), to_u32(d)
    if d == 0:
        return MASK, n  # RISC-V divu/remu convention, documented in divide.s
    return n // d, n % d


class DivideTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.m = Machine(PATH)

    def run_routine(self, n, d):
        self.m.cpu.steps = 0  # the simulator's step budget is cumulative
        self.m.call("udiv", n, d)
        return self.m.reg("a0"), self.m.reg("a1")

    def check(self, n, d):
        q, r = self.run_routine(n, d)
        self.assertEqual((q, r), reference(n, d), f"{to_u32(n)} / {to_u32(d)}")
        if to_u32(d):
            self.assertEqual(q * to_u32(d) + r, to_u32(n))
            self.assertLess(r, to_u32(d))

    def test_known_values(self):
        self.assertEqual(self.run_routine(1000, 7), (142, 6))
        self.assertEqual(self.run_routine(7, 1000), (0, 7))
        self.assertEqual(self.run_routine(MASK, 1), (MASK, 0))
        self.assertEqual(self.run_routine(MASK, MASK), (1, 0))
        self.assertEqual(self.run_routine(MASK, 2), (0x7FFFFFFF, 1))
        # Operands are unsigned: 0xFFFFFFFF is 4294967295, not -1.
        self.assertEqual(self.run_routine(MASK, 0x80000000), (1, 0x7FFFFFFF))

    def test_division_by_zero(self):
        for n in (0, 1, 1000, 0x7FFFFFFF, 0x80000000, MASK):
            self.assertEqual(self.run_routine(n, 0), (MASK, n))

    def test_large_divisors(self):
        # Divisors above 2^31: the quotient is 0 or 1 and the partial
        # remainder gets as close as possible to 32 bits.
        rng = random.Random(50)
        for _ in range(100):
            d = rng.randrange(0x80000000, 2 ** 32)
            n = rng.randrange(0, 2 ** 32)
            self.check(n, d)

    def test_edge_pairs(self):
        for n in PAIR_EDGES:
            for d in PAIR_EDGES:
                self.check(n, d)

    def test_powers_of_two(self):
        rng = random.Random(51)
        for k in range(32):
            self.check(rng.getrandbits(32), 1 << k)

    def test_edge_values(self):
        rng = random.Random(52)
        for x in edge_values():
            self.check(x, rng.getrandbits(rng.randint(1, 32)))
            self.check(rng.getrandbits(32), x)

    def test_random_pairs(self):
        rng = random.Random(53)
        for _ in range(300):
            n = rng.getrandbits(32)
            d = rng.getrandbits(rng.randint(1, 32))  # varied divisor sizes
            self.check(n, d)

    def test_demo_runs(self):
        cpu = run_program(PATH)
        self.assertEqual(cpu.exit_code, 0)
        q1, r1 = reference(1000, 7)
        q2, r2 = reference(1000, 0)
        self.assertEqual(cpu.output.split(), [str(q1), str(r1), str(to_s32(q2)), str(r2)])


if __name__ == "__main__":
    unittest.main()
