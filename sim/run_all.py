"""Co-simulate every program in programs/ plus random instruction streams.

    python3 sim/run_all.py                    # both cores: 34 programs, directed tests, 250 random programs
    python3 sim/run_all.py --core multi       # only the multicycle core
    python3 sim/run_all.py --random 50 --seed 7
    python3 sim/run_all.py --rtl-dir /tmp/mutant_rtl   # test a modified copy of the RTL

For each core the testbench is compiled once; each program then runs in its
own vvp process (in parallel).  For every program the RTL commit trace and
printed output must equal rvsim's exactly.  A summary table is printed for
each core; when both cores run, a table compares their cycle counts and
gives the CPI of the multicycle core (the single-cycle core has CPI 1 by
construction).  The exit code is 0 only if everything matches.
"""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from cosim import (  # noqa: E402
    CORES, DEFAULT_MAX_STEPS, REPO, RTL_DIR, CosimError, CosimResult, compile_testbench, cosimulate,
)
from directed_tests import DIRECTED, MAX_STEPS  # noqa: E402
from random_programs import generate  # noqa: E402


def program_files() -> list[Path]:
    return sorted((REPO / "programs").glob("*/*.s"))


def run_suite(rtl_dir: str | Path = RTL_DIR, n_random: int = 250, seed: int = 2026,
              programs: list[Path] | None = None, jobs: int | None = None,
              max_steps: int = DEFAULT_MAX_STEPS, directed: bool = True,
              stop_on_first: bool = False,
              core: str = "single") -> list[tuple[str, str, CosimResult | str]]:
    """Run the co-simulation of one core; return (group, name, result-or-error) tuples."""
    programs = program_files() if programs is None else programs
    cases: list[tuple[str, str, str, int]] = []
    for path in programs:
        cases.append(("program", str(path.relative_to(REPO)), path.read_text(encoding="utf-8"), max_steps))
    if directed:
        for name, source in DIRECTED.items():
            cases.append(("directed", name, source, MAX_STEPS.get(name, max_steps)))
    for k in range(n_random):
        cases.append(("random", f"random seed {seed + k}", generate(seed + k), max_steps))

    results: list[tuple[str, str, CosimResult | str]] = []
    with tempfile.TemporaryDirectory(prefix="cosim_all_") as tmp:
        vvp = compile_testbench(Path(tmp) / "tb.vvp", rtl_dir, core)

        def one(index: int) -> tuple[str, str, CosimResult | str]:
            group, name, source, limit = cases[index]
            workdir = Path(tmp) / f"case{index}"
            try:
                return group, name, cosimulate(source, workdir, vvp, limit)
            except Exception as exc:  # report, do not abort the whole suite
                return group, name, f"error: {exc}"

        with ThreadPoolExecutor(max_workers=jobs or os.cpu_count() or 4) as pool:
            for item in pool.map(one, range(len(cases))):
                results.append(item)
                ok = isinstance(item[2], CosimResult) and item[2].ok
                if stop_on_first and not ok:
                    pool.shutdown(wait=False, cancel_futures=True)
                    break
    return results


def _passed(result: CosimResult | str) -> bool:
    return isinstance(result, CosimResult) and result.ok


Results = list[tuple[str, str, CosimResult | str]]


def print_core_report(core: str, results: Results, seed: int) -> list[tuple[str, CosimResult | str]]:
    """Per-program table and summary of one core; returns its failures."""
    progs = [r for r in results if r[0] == "program"]
    dirs = [r for r in results if r[0] == "directed"]
    rands = [r for r in results if r[0] == "random"]

    print(f"===== core: {core} =====")
    if progs or dirs:
        width = max(len(name) for _, name, _ in progs + dirs)
        print(f"{'program':<{width}}  {'instructions':>12}  {'cycles':>8}  {'end':<26}  result")
        print("-" * (width + 64))
        for _, name, res in progs + dirs:
            if isinstance(res, CosimResult):
                cycles = "-" if res.cycles is None else str(res.cycles)
                print(f"{name:<{width}}  {res.instructions:>12}  {cycles:>8}  {res.end:<26}  "
                      f"{'MATCH' if res.ok else 'MISMATCH'}")
            else:
                print(f"{name:<{width}}  {'-':>12}  {'-':>8}  {'-':<26}  ERROR")
        print()

    failures = [(name, res) for _, name, res in results if not _passed(res)]
    for name, res in failures[:10]:
        print(f"--- {name}")
        print(res.message if isinstance(res, CosimResult) else res)
    if len(failures) > 10:
        print(f"... and {len(failures) - 10} more failures")

    total_instr = sum(r.instructions for _, _, r in results if isinstance(r, CosimResult))
    print(f"summary [{core}]")
    print(f"  programs : {sum(_passed(r) for _, _, r in progs)}/{len(progs)} match")
    print(f"  directed : {sum(_passed(r) for _, _, r in dirs)}/{len(dirs)} match")
    print(f"  random   : {sum(_passed(r) for _, _, r in rands)}/{len(rands)} match "
          f"(seeds {seed}..{seed + len(rands) - 1})")
    print(f"  retired instructions compared: {total_instr}")
    print()
    return failures


def print_cpi_table(single: Results, multi: Results) -> None:
    """Cycle counts of both cores on the programs, and the multicycle CPI."""
    multi_by_name = {name: res for group, name, res in multi if group == "program"}
    rows = []
    for group, name, res in single:
        other = multi_by_name.get(name)
        if group != "program" or not isinstance(res, CosimResult) or not isinstance(other, CosimResult):
            continue
        if res.cycles is None or other.cycles is None or other.cpi is None:
            continue
        rows.append((name, res.instructions, res.cycles, other.cycles, other.cpi))
    if not rows:
        return
    width = max(len(r[0]) for r in rows)
    print("===== cycles: single-cycle vs multicycle =====")
    print(f"{'program':<{width}}  {'instructions':>12}  {'single cycles':>13}  {'multi cycles':>12}  {'CPI':>6}")
    print("-" * (width + 53))
    for name, instr, s_cyc, m_cyc, cpi in rows:
        print(f"{name:<{width}}  {instr:>12}  {s_cyc:>13}  {m_cyc:>12}  {cpi:>6.3f}")
    print("-" * (width + 53))
    total_i = sum(r[1] for r in rows)
    total_s = sum(r[2] for r in rows)
    total_m = sum(r[3] for r in rows)
    print(f"{'total':<{width}}  {total_i:>12}  {total_s:>13}  {total_m:>12}  {total_m / total_i:>6.3f}")
    print(f"average CPI over {len(rows)} programs: {sum(r[4] for r in rows) / len(rows):.3f} "
          f"(per-program mean); {total_m / total_i:.3f} (all instructions together)")
    print()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="co-simulate all programs and random tests")
    parser.add_argument("--core", choices=(*CORES, "both"), default="both",
                        help="processor core(s) to test (default: both)")
    parser.add_argument("--random", type=int, default=250, metavar="N", help="number of random programs")
    parser.add_argument("--seed", type=int, default=2026, help="first random seed")
    parser.add_argument("--rtl-dir", default=str(RTL_DIR), help="directory of the RTL to test")
    parser.add_argument("--jobs", type=int, default=None, help="parallel simulations")
    parser.add_argument("--no-programs", action="store_true", help="only run the random programs")
    args = parser.parse_args(argv)

    cores = list(CORES) if args.core == "both" else [args.core]
    start = time.time()
    all_results: dict[str, Results] = {}
    failed = False
    for core in cores:
        try:
            all_results[core] = run_suite(args.rtl_dir, args.random, args.seed,
                                          [] if args.no_programs else None, args.jobs,
                                          directed=not args.no_programs, core=core)
        except CosimError as exc:
            print(f"error [{core}]: {exc}", file=sys.stderr)
            return 1
        if print_core_report(core, all_results[core], args.seed):
            failed = True

    if len(cores) == 2:
        print_cpi_table(all_results["single"], all_results["multi"])
    print(f"overall: {'ALL MATCH' if not failed else 'FAILURES'} on core(s) {', '.join(cores)}")
    print(f"time: {time.time() - start:.1f} s")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
