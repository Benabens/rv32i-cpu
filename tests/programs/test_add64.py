"""Tests for programs/arith/add64.s (64-bit add and subtract on register pairs)."""

import random
import unittest

from tests.programs.harness import Machine, run_program, to_s32, to_u32

PATH = "programs/arith/add64.s"
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

MASK64 = (1 << 64) - 1


def split(v):
    return v & MASK, (v >> 32) & MASK


class Add64Test(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.m = Machine(PATH)

    def run_routine(self, name, x, y):
        x_lo, x_hi = split(x)
        y_lo, y_hi = split(y)
        self.m.cpu.steps = 0  # the simulator's step budget is cumulative
        self.m.call(name, x_lo, x_hi, y_lo, y_hi)
        return (self.m.reg("a1") << 32) | self.m.reg("a0")

    def check(self, x, y):
        self.assertEqual(self.run_routine("add64", x, y), (x + y) & MASK64, f"{x:#x} + {y:#x}")
        self.assertEqual(self.run_routine("sub64", x, y), (x - y) & MASK64, f"{x:#x} - {y:#x}")

    def test_carry_crosses_word_boundary(self):
        self.assertEqual(self.run_routine("add64", 0x1_FFFFFFFF, 1), 0x2_00000000)
        self.assertEqual(self.run_routine("add64", 0xFFFFFFFF, 0xFFFFFFFF), 0x1_FFFFFFFE)
        self.assertEqual(self.run_routine("sub64", 0x2_00000000, 1), 0x1_FFFFFFFF)
        self.assertEqual(self.run_routine("sub64", 0, 1), MASK64)

    def test_wraps_modulo_2_64(self):
        self.assertEqual(self.run_routine("add64", MASK64, 1), 0)
        self.assertEqual(self.run_routine("add64", MASK64, MASK64), MASK64 - 1)

    def test_signed_interpretation(self):
        # -5 + 3 = -2 and 3 - 5 = -2 as signed 64-bit numbers
        self.assertEqual(self.run_routine("add64", (-5) & MASK64, 3), (-2) & MASK64)
        self.assertEqual(self.run_routine("sub64", 3, 5), (-2) & MASK64)

    def test_edge_pairs(self):
        # Every combination of edge words in both halves of both operands
        # would be too many; combine edge low words with edge high words.
        words = PAIR_EDGES
        rng = random.Random(30)
        for lo1 in words:
            for lo2 in words:
                hi1, hi2 = rng.choice(words), rng.choice(words)
                self.check((hi1 << 32) | lo1, (hi2 << 32) | lo2)

    def test_random_pairs(self):
        rng = random.Random(31)
        for _ in range(300):
            self.check(rng.getrandbits(64), rng.getrandbits(64))

    def test_demo_runs(self):
        cpu = run_program(PATH)
        self.assertEqual(cpu.exit_code, 0)
        total = 0x1_FFFFFFFF + 1
        back = total - 1
        self.assertEqual(cpu.output.split(),
                         [str(to_s32(total >> 32)), str(to_s32(total)),
                          str(to_s32(back >> 32)), str(to_s32(back))])


if __name__ == "__main__":
    unittest.main()
