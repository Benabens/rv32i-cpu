"""Tests for programs/bits/byte_swap.s (endianness swap)."""

import random
import unittest

from tests.programs.harness import Machine, run_program, to_s32, to_u32

PATH = "programs/bits/byte_swap.s"
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


def reference(x):
    # Serialise little-endian, read back big-endian.
    return int.from_bytes(to_u32(x).to_bytes(4, "little"), "big")


class ByteSwapTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.m = Machine(PATH)

    def run_routine(self, x):
        self.m.cpu.steps = 0  # the simulator's step budget is cumulative
        return self.m.call("byte_swap", x)

    def test_known_values(self):
        self.assertEqual(self.run_routine(0x11223344), 0x44332211)
        self.assertEqual(self.run_routine(0x000000FF), 0xFF000000)
        self.assertEqual(self.run_routine(0x80000000), 0x00000080)
        self.assertEqual(self.run_routine(0), 0)
        self.assertEqual(self.run_routine(MASK), MASK)

    def test_edge_values(self):
        for x in edge_values():
            self.assertEqual(self.run_routine(x), reference(x), f"{x:#010x}")

    def test_random_values_and_involution(self):
        for x in random_values(seed=44):
            r = self.run_routine(x)
            self.assertEqual(r, reference(x), f"{x:#010x}")
            self.assertEqual(self.run_routine(r), x, "swapping twice is the identity")

    def test_matches_memory_layout(self):
        # A word stored with sw and read back byte by byte from the lowest
        # address gives the bytes of byte_swap(x) in big-endian order.
        rng = random.Random(45)
        for _ in range(50):
            x = rng.getrandbits(32)
            buf = self.m.words([x])
            in_memory = self.m.read_bytes(buf, 4)
            self.assertEqual(in_memory, self.run_routine(x).to_bytes(4, "big"))

    def test_demo_runs(self):
        cpu = run_program(PATH)
        self.assertEqual(cpu.exit_code, 0)
        self.assertEqual(cpu.output.split(), ["68", "17", str(to_s32(reference(0x11223344)))])


if __name__ == "__main__":
    unittest.main()
