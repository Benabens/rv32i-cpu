"""Tests for programs/demo/automata.s (elementary cellular automata 90 and 30).

The reference evolves the automaton cell by cell from the rule's truth table,
a list of 0/1 values -- unlike the assembly program, which updates 32 cells at
once with bitwise operations on shifted copies of the row.
"""

import math
import random
import unittest

from tests.programs.harness import Machine, run_program

PATH = "programs/demo/automata.s"
WIDTH, GENERATIONS, SEED = 64, 32, 31
TITLE = "Elementary cellular automata on RV32I -- 64 cells, 32 generations, bit-parallel\n"
RULES = [(90, ": new cell = left XOR right  (Pascal's triangle mod 2)\n"),
         (30, ": new cell = left XOR (centre OR right)\n")]


def step(cells, rule):
    """One generation; cells outside the row are dead."""
    padded = [0] + cells + [0]
    return [(rule >> (4 * padded[i] + 2 * padded[i + 1] + padded[i + 2])) & 1
            for i in range(len(cells))]


def history(rule):
    cells = [0] * WIDTH
    cells[SEED] = 1
    rows = []
    for _ in range(GENERATIONS):
        rows.append(cells)
        cells = step(cells, rule)
    return rows


def render(cells):
    return "".join("#" if c else " " for c in cells).rstrip()


def reference_output():
    out = [TITLE]
    for rule, desc in RULES:
        rows = history(rule)
        out.append(f"\nRule {rule}{desc}")
        out.extend(render(r) + "\n" for r in rows)
        out.append(f"{sum(map(sum, rows))} live cells\n")
    return "".join(out)


def cells_to_words(cells):
    value = 0
    for c in cells:                     # leftmost cell = bit 63
        value = (value << 1) | c
    return value >> 32, value & 0xFFFFFFFF


class AutomataDemoTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cpu = run_program(PATH)

    def test_exits_cleanly(self):
        self.assertEqual(self.cpu.exit_code, 0)

    def test_output_matches_reference(self):
        self.assertEqual(self.cpu.output, reference_output())

    def picture(self, index):
        lines = self.cpu.output.split("\n")
        start = 3 + index * (GENERATIONS + 3)
        return lines[start:start + GENERATIONS], lines[start + GENERATIONS]

    def test_rule90_is_pascal_triangle_mod_2(self):
        rows, live = self.picture(0)
        for n, line in enumerate(rows):
            expected = [" "] * WIDTH
            for k in range(n + 1):
                if math.comb(n, k) % 2:
                    expected[SEED - n + 2 * k] = "#"
            self.assertEqual(line, "".join(expected).rstrip(), n)
        self.assertEqual(live, f"{3 ** 5} live cells")    # Gould's sequence

    def test_rule30_left_edge_and_symmetry_breaking(self):
        rows, _ = self.picture(1)
        for n, line in enumerate(rows):
            # rule 30's left border is a straight diagonal of live cells
            self.assertEqual(line.index("#"), SEED - n, n)
        self.assertNotEqual(rows[-1], rows[-1][::-1])      # not mirror-symmetric


class StepRoutineTest(unittest.TestCase):
    """ca_step called directly with random rows and all 256 rules."""

    @classmethod
    def setUpClass(cls):
        cls.m = Machine(PATH)

    def test_random_rows_all_rules(self):
        rng = random.Random(30)
        for rule in range(256):
            cells = [rng.getrandbits(1) for _ in range(WIDTH)]
            hi, lo = cells_to_words(cells)
            self.m.call("ca_step", hi, lo, rule)
            self.assertEqual((self.m.reg("a0"), self.m.reg("a1")),
                             cells_to_words(step(cells, rule)), rule)

    def test_print_row_counts_live_cells(self):
        rng = random.Random(90)
        for _ in range(20):
            cells = [rng.getrandbits(1) for _ in range(WIDTH)]
            before = len(self.m.cpu.output)
            count = self.m.call("print_row", *cells_to_words(cells))
            self.assertEqual(count, sum(cells))
            self.assertEqual(self.m.cpu.output[before:], render(cells) + "\n")


if __name__ == "__main__":
    unittest.main()
