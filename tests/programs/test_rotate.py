"""Tests for programs/bits/rotate.s (rotl and rotr)."""

import random
import unittest

from tests.programs.harness import Machine, run_program, to_s32, to_u32

PATH = "programs/bits/rotate.s"
MASK = 0xFFFFFFFF


def edge_values():
    values = {0, 1, 2, 3, MASK, MASK - 1, 0x7FFFFFFF, 0x80000000, 0x80000001,
              0x55555555, 0xAAAAAAAA, 0x33333333, 0xCCCCCCCC, 0x0F0F0F0F,
              0xF0F0F0F0, 0x00FF00FF, 0xFF00FF00, 0x0000FFFF, 0xFFFF0000,
              0x12345678, 0xDEADBEEF}
    for k in range(32):
        values |= {1 << k, (1 << k) - 1, MASK ^ (1 << k)}
    return sorted(values)


def random_values(seed, n=300):
    rng = random.Random(seed)
    return [rng.getrandbits(32) for _ in range(n)]


def ref_rotl(x, n):
    # Rotate the 32-character binary string: independent of shift formulas.
    s = format(to_u32(x), "032b")
    n %= 32
    return int(s[n:] + s[:n], 2)


def ref_rotr(x, n):
    s = format(to_u32(x), "032b")
    n %= 32
    return int(s[32 - n:] + s[:32 - n], 2)


class RotateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.m = Machine(PATH)

    def run_routine(self, name, x, n):
        self.m.cpu.steps = 0  # the simulator's step budget is cumulative
        return self.m.call(name, x, n)

    def check(self, x, n):
        self.assertEqual(self.run_routine("rotl", x, n), ref_rotl(x, n), f"rotl({x:#010x}, {n})")
        self.assertEqual(self.run_routine("rotr", x, n), ref_rotr(x, n), f"rotr({x:#010x}, {n})")

    def test_known_values(self):
        self.assertEqual(self.run_routine("rotl", 0x80000001, 1), 0x00000003)
        self.assertEqual(self.run_routine("rotr", 0x80000001, 1), 0xC0000000)
        self.assertEqual(self.run_routine("rotl", 0x12345678, 8), 0x34567812)
        self.assertEqual(self.run_routine("rotr", 0x12345678, 8), 0x78123456)

    def test_zero_and_full_rotation_are_identity(self):
        for x in edge_values():
            for n in (0, 32, 64):
                self.assertEqual(self.run_routine("rotl", x, n), x)
                self.assertEqual(self.run_routine("rotr", x, n), x)

    def test_all_amounts_on_edge_patterns(self):
        for x in (1, 0x80000000, 0x80000001, 0x7FFFFFFF, MASK, 0xAAAAAAAA, 0xDEADBEEF, 0x0000FFFF):
            for n in range(33):
                self.check(x, n)

    def test_amount_is_taken_modulo_32(self):
        for n in (33, 40, 63, 100, -1, -5, -31, 0x7FFFFFFF):
            self.check(0x12345678, n)
        # rotl by -n is rotr by n
        self.assertEqual(self.run_routine("rotl", 0xCAFEBABE, -3), ref_rotr(0xCAFEBABE, 3))

    def test_edge_values(self):
        rng = random.Random(9)
        for x in edge_values():
            self.check(x, rng.randrange(32))

    def test_random_values_and_inverse(self):
        rng = random.Random(10)
        for _ in range(300):
            x, n = rng.getrandbits(32), rng.randrange(64)
            self.check(x, n)
            left = self.run_routine("rotl", x, n)
            self.assertEqual(self.run_routine("rotr", left, n), x, "rotr undoes rotl")

    def test_demo_runs(self):
        cpu = run_program(PATH)
        self.assertEqual(cpu.exit_code, 0)
        self.assertEqual(cpu.output.split(),
                         [str(to_s32(ref_rotl(0x80000001, 1))), str(to_s32(ref_rotr(0x80000001, 1)))])


if __name__ == "__main__":
    unittest.main()
