"""Tests for programs/demo/primes.s (Sieve of Eratosthenes, table output)."""

import unittest

from tests.programs.harness import Machine, run_program

PATH = "programs/demo/primes.s"
N = 2000
COLUMNS = 15
TITLE = "Sieve of Eratosthenes on RV32I -- all primes up to 2000\n"


def is_prime(k):
    """Trial division: independent of the sieve."""
    if k < 2:
        return False
    d = 2
    while d * d <= k:
        if k % d == 0:
            return False
        d += 1
    return True


def primes_up_to(n):
    return [k for k in range(2, n + 1) if is_prime(k)]


def reference_output():
    primes = primes_up_to(N)
    lines = []
    for i in range(0, len(primes), COLUMNS):
        lines.append("".join(f"{p:5d}" for p in primes[i:i + COLUMNS]) + "\n")
    footer = f"{len(primes)} primes up to {N}, the largest is {primes[-1]}\n"
    return TITLE + "".join(lines) + footer


class PrimesDemoTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cpu = run_program(PATH)

    def test_exits_cleanly(self):
        self.assertEqual(self.cpu.exit_code, 0)

    def test_output_matches_reference(self):
        self.assertEqual(self.cpu.output, reference_output())

    def test_known_prime_count(self):
        # pi(2000) = 303, the largest prime below 2000 is 1999
        self.assertTrue(self.cpu.output.endswith("303 primes up to 2000, the largest is 1999\n"))
        numbers = [int(t) for line in self.cpu.output.splitlines()[1:-1] for t in line.split()]
        self.assertEqual(len(numbers), 303)
        self.assertEqual(numbers, sorted(numbers))

    def test_table_layout(self):
        rows = self.cpu.output.splitlines()[1:-1]
        self.assertEqual(len(rows), 21)                     # ceil(303 / 15)
        self.assertTrue(all(len(r) == 5 * COLUMNS for r in rows[:-1]))
        self.assertEqual(len(rows[-1]), 5 * (303 % COLUMNS))


class SieveRoutinesTest(unittest.TestCase):
    """sieve and collect called directly for other limits."""

    def run_sieve(self, n):
        m = Machine(PATH)
        flags = m.space(n + 1)
        out = m.space(2 * (n // 2 + 2))
        m.call("sieve", flags, n, max_steps=1_000_000)
        flag_bytes = m.read_bytes(flags, n + 1)
        count = m.call("collect", flags, n, out, max_steps=1_000_000)
        halfwords = m.read_bytes(out, 2 * count)
        listed = [int.from_bytes(halfwords[2 * i:2 * i + 2], "little") for i in range(count)]
        return flag_bytes, listed

    def test_flags_mark_exactly_the_composites(self):
        n = 500
        flags, _ = self.run_sieve(n)
        for k in range(4, n + 1):
            self.assertEqual(flags[k], 0 if is_prime(k) else 1, k)

    def test_various_limits(self):
        known_pi = {2: 1, 3: 2, 4: 2, 10: 4, 29: 10, 30: 10, 100: 25, 121: 30, 1000: 168, 4096: 564}
        for n, pi in known_pi.items():
            _, listed = self.run_sieve(n)
            self.assertEqual(listed, primes_up_to(n), n)
            self.assertEqual(len(listed), pi, n)


if __name__ == "__main__":
    unittest.main()
