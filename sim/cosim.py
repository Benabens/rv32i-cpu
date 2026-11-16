"""Co-simulation of the Verilog processor against the rvsim golden model.

For one assembly program:

1. assemble it with rvsim and write the memory images (``text.hex``,
   ``data.hex``, ``meta.txt``);
2. run the RTL testbench (Icarus Verilog) on the images: it writes a commit
   trace and the program's printed output;
3. compute rvsim's commit trace of the same program;
4. compare the two traces line by line, then the printed output.

On a mismatch the FIRST divergence is reported: retired-instruction index,
pc, source line, disassembly, and the two trace lines.

Two processor cores share the testbench: ``single`` (cpu_single_cycle.v,
one instruction per clock cycle) and ``multi`` (cpu_multi_cycle.v, 2 to 5
cycles per instruction).  The testbench also reports the number of clock
cycles the core needed, from which the CPI is computed.

Usage::

    python3 sim/cosim.py programs/functions/hanoi.s [--core single|multi] [--keep DIR] [--max-steps N]

Exit code 0 if the hardware matches the model exactly, 1 otherwise.
The functions are also used by ``sim/run_all.py`` and ``tests/test_cosim.py``.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from rvsim import AssemblerError, Program, assemble, decode, trace_program, write_build  # noqa: E402
from rvsim.encoding import EncodingError  # noqa: E402

TESTBENCH = REPO / "sim" / "tb_cpu.v"
RTL_DIR = REPO / "rtl"
DEFAULT_MAX_STEPS = 1_000_000
CORES = ("single", "multi")
CORE_DEFINES = {"single": [], "multi": ["-DCORE_MULTI_CYCLE"]}


class CosimError(Exception):
    """The co-simulation could not be run (missing tool, compile error, ...)."""


def find_tool(name: str) -> str | None:
    """Path of an Icarus Verilog executable, or None if it is not installed."""
    found = shutil.which(name)
    if found:
        return found
    for prefix in ("/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"):
        candidate = Path(prefix) / name
        if candidate.exists():
            return str(candidate)
    return None


def compile_testbench(out_file: str | Path, rtl_dir: str | Path = RTL_DIR,
                      core: str = "single") -> Path:
    """Compile the RTL in ``rtl_dir`` with the testbench into a vvp executable.

    ``core`` selects the processor instantiated by the testbench: ``"single"``
    or ``"multi"``.
    """
    if core not in CORE_DEFINES:
        raise CosimError(f"unknown core {core!r} (expected one of {', '.join(CORES)})")
    iverilog = find_tool("iverilog")
    if iverilog is None:
        raise CosimError("iverilog not found (install Icarus Verilog)")
    rtl_dir = Path(rtl_dir)
    sources = sorted(str(p) for p in rtl_dir.glob("*.v"))
    out_file = Path(out_file)
    cmd = [iverilog, "-g2005", "-Wall", "-I", str(rtl_dir), *CORE_DEFINES[core], "-s", "tb_cpu",
           "-o", str(out_file), *sources, str(TESTBENCH)]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise CosimError(f"iverilog failed:\n{proc.stdout}{proc.stderr}")
    return out_file


def run_rtl(vvp_file: str | Path, build_dir: str | Path, meta: dict[str, int],
            max_steps: int = DEFAULT_MAX_STEPS, timeout: float = 300) -> tuple[list[str], str]:
    """Run the compiled testbench on the images in ``build_dir``.

    Returns the RTL commit trace (list of lines) and the printed output.
    The cycle statistics are left in ``rtl_stats.txt`` (see :func:`read_stats`).
    """
    vvp = find_tool("vvp")
    if vvp is None:
        raise CosimError("vvp not found (install Icarus Verilog)")
    build_dir = Path(build_dir)
    trace_file, out_file = build_dir / "rtl_trace.txt", build_dir / "rtl_output.txt"
    (build_dir / "rtl_stats.txt").unlink(missing_ok=True)
    cmd = [
        vvp, "-n", str(vvp_file),
        f"+text={build_dir / 'text.hex'}", f"+text_words={meta['text_words']}",
        f"+data={build_dir / 'data.hex'}", f"+data_words={meta['data_words']}",
        f"+entry={meta['entry']:x}", f"+text_end={meta['text_end']:x}",
        f"+trace={trace_file}", f"+out={out_file}", f"+max={max_steps}", "+quiet",
        f"+stats={build_dir / 'rtl_stats.txt'}",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if not trace_file.exists():
        raise CosimError(f"the testbench produced no trace:\n{proc.stdout}{proc.stderr}")
    lines = trace_file.read_text(encoding="ascii", errors="replace").splitlines()
    output = out_file.read_bytes().decode("utf-8", errors="replace") if out_file.exists() else ""
    return lines, output


def read_stats(build_dir: str | Path) -> dict[str, int]:
    """Cycle statistics written by the testbench: {'instructions': n, 'cycles': n}."""
    stats: dict[str, int] = {}
    path = Path(build_dir) / "rtl_stats.txt"
    if path.exists():
        for line in path.read_text(encoding="ascii").splitlines():
            key, _, value = line.partition(" ")
            if value.strip().isdigit():
                stats[key] = int(value)
    return stats


@dataclass
class CosimResult:
    ok: bool
    instructions: int          # instructions retired by the reference model
    end: str                   # final line of the reference trace
    message: str = ""          # divergence report when ok is False
    cycles: int | None = None  # clock cycles the core needed (None if unknown)

    @property
    def cpi(self) -> float | None:
        """Cycles per instruction of the hardware run."""
        if self.cycles is None or self.instructions == 0:
            return None
        return self.cycles / self.instructions


def _describe(line: str, program: Program) -> str:
    """'pc 0x.. (line N): disassembly' for a trace line, as far as it can be parsed."""
    parts = line.split()
    if len(parts) < 2:
        return line
    try:
        pc, word = int(parts[0], 16), int(parts[1], 16)
    except ValueError:
        return line
    try:
        text = decode(word)
    except EncodingError:
        text = f"<illegal 0x{word:08x}>"
    src = program.line_at(pc)
    where = f" (source line {src})" if src is not None else ""
    return f"pc 0x{pc:08x}{where}: {text}"


def compare_traces(expected: list[str], actual: list[str], program: Program) -> str | None:
    """None if the traces are identical, else a report of the first divergence."""
    for i in range(max(len(expected), len(actual))):
        exp = expected[i] if i < len(expected) else "<trace ended>"
        act = actual[i] if i < len(actual) else "<trace ended>"
        if exp != act:
            ref = exp if i < len(expected) and not exp.startswith(("HALT", "TRAP", "TIMEOUT")) else act
            report = [f"first divergence at retired instruction #{i}"]
            report.append("  " + _describe(ref, program))
            report.append(f"  rvsim : {exp}")
            report.append(f"  rtl   : {act}")
            if i > 0:
                report.append(f"  (previous, identical: {expected[i - 1]})")
            return "\n".join(report)
    return None


def cosimulate(source: str, workdir: str | Path, vvp_file: str | Path,
               max_steps: int = DEFAULT_MAX_STEPS) -> CosimResult:
    """Co-simulate one program given as assembly source."""
    program = assemble(source)
    meta = write_build(program, workdir)
    expected = trace_program(program, max_steps)
    # The hardware never needs to run longer than the model plus one
    # instruction: one extra record is enough to show a divergence.  This
    # keeps a buggy design that loops forever from running to max_steps.
    rtl_limit = min(max_steps, len(expected.commits) + 1)
    actual_lines, actual_output = run_rtl(vvp_file, workdir, meta, rtl_limit)
    exp_lines = expected.lines()
    report = compare_traces(exp_lines, actual_lines, program)
    if report is None and actual_output != expected.output:
        report = (f"traces match but the printed output differs\n"
                  f"  rvsim : {expected.output!r}\n  rtl   : {actual_output!r}")
    cycles = read_stats(workdir).get("cycles")
    return CosimResult(report is None, len(expected.commits), expected.end, report or "", cycles)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="co-simulate one program: RTL vs rvsim")
    parser.add_argument("file", help="assembly source file")
    parser.add_argument("--keep", metavar="DIR", help="keep the images and traces in DIR")
    parser.add_argument("--rtl-dir", default=str(RTL_DIR), help="directory of the RTL to test")
    parser.add_argument("--core", choices=CORES, default="single",
                        help="processor core to simulate (default: single)")
    parser.add_argument("--max-steps", type=int, default=DEFAULT_MAX_STEPS, metavar="N")
    args = parser.parse_args(argv)

    try:
        source = Path(args.file).read_text(encoding="utf-8")
    except OSError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory(prefix="cosim_") as tmp:
        workdir = Path(args.keep) if args.keep else Path(tmp)
        workdir.mkdir(parents=True, exist_ok=True)
        try:
            vvp = compile_testbench(Path(tmp) / "tb.vvp", args.rtl_dir, args.core)
            result = cosimulate(source, workdir, vvp, args.max_steps)
        except (CosimError, AssemblerError, subprocess.TimeoutExpired) as exc:
            print(f"{args.file}: error: {exc}", file=sys.stderr)
            return 1
    if result.ok:
        timing = ""
        if result.cycles is not None and result.cpi is not None:
            timing = f", {result.cycles} cycles, CPI {result.cpi:.3f}"
        print(f"{args.file}: MATCH [{args.core}] ({result.instructions} instructions{timing}, {result.end})")
        return 0
    print(f"{args.file}: MISMATCH\n{result.message}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
