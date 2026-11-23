"""Mutation check: does the co-simulation catch real hardware bugs?

Each mutant is a copy of rtl/ with ONE deliberate, realistic bug (a wrong
comparison, a wrong immediate bit, a wrong byte enable ...).  The whole
co-simulation suite is run on every mutant; a mutant is "killed" when at
least one program diverges from the reference model.  The repository's RTL
is never modified: mutants live in a temporary directory.

Two families of mutants:

* ``single``: datapath and decoder bugs, simulated on the single-cycle core;
* ``multi``: state-machine bugs of the multicycle core (a step done in the
  wrong state, a register latched too early or too late, a state skipped),
  simulated on the multicycle core.

    python3 sim/mutation_check.py [--core single|multi|both] [--random N]

Exit code 0 only if every mutant is killed (and the unmodified RTL passes).
"""

from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from cosim import RTL_DIR, CosimResult  # noqa: E402
from run_all import run_suite  # noqa: E402

# (description, file, original text, mutated text)
MUTANTS: list[tuple[str, str, str, str]] = [
    ("sltu computed as signed slt", "alu.v",
     "`ALU_SLTU: result = {31'd0, a < b};",
     "`ALU_SLTU: result = {31'd0, a_signed < b_signed};"),
    ("sra computed as logical shift", "alu.v",
     "`ALU_SRA:  result = a_signed >>> shamt;",
     "`ALU_SRA:  result = a >> shamt;"),
    ("shift amount not truncated to 5 bits", "alu.v",
     "`ALU_SLL:  result = a << shamt;",
     "`ALU_SLL:  result = a << b;"),
    ("B-immediate bit 11 taken from instr[8] instead of instr[7]", "imm_gen.v",
     "`IMM_B:  imm = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};",
     "`IMM_B:  imm = {{20{instr[31]}}, instr[8], instr[30:25], instr[11:8], 1'b0};"),
    ("J-immediate bit 11 and bits 19:12 swapped in position", "imm_gen.v",
     "`IMM_J:  imm = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};",
     "`IMM_J:  imm = {{12{instr[31]}}, instr[20], instr[19:12], instr[30:21], 1'b0};"),
    ("lb zero-extends", "load_store_unit.v",
     "`SIZE_BYTE: load_data = {{24{load_byte[7]  & ~unsigned_load}}, load_byte};",
     "`SIZE_BYTE: load_data = {24'd0, load_byte};"),
    ("lhu sign-extends", "load_store_unit.v",
     "`SIZE_HALF: load_data = {{16{load_half[15] & ~unsigned_load}}, load_half};",
     "`SIZE_HALF: load_data = {{16{load_half[15]}}, load_half};"),
    ("sh at offset 2 writes the middle bytes", "load_store_unit.v",
     "byte_en   = offset[1] ? 4'b1100 : 4'b0011;",
     "byte_en   = offset[1] ? 4'b0110 : 4'b0011;"),
    ("sb ignores the byte offset", "load_store_unit.v",
     "byte_en   = 4'b0001 << offset;",
     "byte_en   = 4'b0001;"),
    ("jalr does not clear bit 0 of the target", "cpu_single_cycle.v",
     "next_pc = {alu_result[31:1], 1'b0};",
     "next_pc = alu_result;"),
    ("jal / jalr link pc instead of pc + 4", "cpu_single_cycle.v",
     "`WB_PC4: wb_value = pc_plus4;",
     "`WB_PC4: wb_value = pc;"),
    ("auipc adds the immediate to pc + 4", "cpu_single_cycle.v",
     "`SRCA_PC:   alu_a = pc;",
     "`SRCA_PC:   alu_a = pc_plus4;"),
    ("x0 writable (write guard and read gating removed)", "regfile.v",
     "assign rdata1 = (raddr1 == 5'd0) ? 32'd0 : regs[raddr1];",
     "assign rdata1 = regs[raddr1];"),
    ("bltu / bgeu compare signed", "branch_unit.v",
     "wire less_unsigned = (rs1 < rs2);",
     "wire less_unsigned = ($signed(rs1) < $signed(rs2));"),
    ("bit 30 of an I-immediate turns addi into a subtraction", "control.v",
     "wire alt = instr[30] && (opcode == `OPC_OP || funct3 == 3'b101);",
     "wire alt = instr[30];"),
]

# State-machine bugs of the multicycle core (cpu_multi_cycle.v and
# multicycle_control.v), same format.
MULTI_MUTANTS: list[tuple[str, str, str, str]] = [
    ("loads skip WRITEBACK (MEMORY returns straight to FETCH)", "multicycle_control.v",
     """                if (is_load)
                    next_state = S_WRITEBACK;""",
     """                if (is_load)
                    next_state = S_FETCH;"""),
    ("pc also incremented in FETCH (pc updated in the wrong state)", "multicycle_control.v",
     "assign pc_write = done;",
     "assign pc_write = done | (state == S_FETCH);"),
    ("register file also written in the FETCH after WRITEBACK (rd written twice)", "multicycle_control.v",
     "assign rf_write_state = (state == S_WRITEBACK);",
     "assign rf_write_state = (state == S_WRITEBACK) || (state == S_FETCH);"),
    ("store issued in EXECUTE as well as in MEMORY", "cpu_multi_cycle.v",
     "wire store_now = mem_write & mem_state;",
     "wire store_now = mem_write & (mem_state | alu_out_write);"),
    ("branch / jal target latched in FETCH, one state too early", "multicycle_control.v",
     "assign target_write   = (state == S_DECODE);",
     "assign target_write   = (state == S_FETCH);"),
    ("A / B operand registers latched in FETCH (previous instruction's sources)", "multicycle_control.v",
     "assign operands_write = (state == S_DECODE);",
     "assign operands_write = (state == S_FETCH);"),
    ("ALU operand A in DECODE selects the old A register instead of the pc", "cpu_multi_cycle.v",
     """        if (decode_state)
            alu_a = pc;""",
     """        if (decode_state)
            alu_a = reg_a;"""),
    ("load data register latched in WRITEBACK, one state too late", "multicycle_control.v",
     "assign mdr_write      = (state == S_MEMORY);",
     "assign mdr_write      = (state == S_WRITEBACK);"),
]

# The x0 mutant also needs the write guard removed to be a real "writable x0".
EXTRA_EDITS = {
    "x0 writable (write guard and read gating removed)": [
        ("regfile.v",
         "end else if (we && waddr != 5'd0) begin",
         "end else if (we) begin"),
        ("regfile.v",
         "assign rdata2 = (raddr2 == 5'd0) ? 32'd0 : regs[raddr2];",
         "assign rdata2 = regs[raddr2];"),
    ],
}


def make_mutant(target: Path, edits: list[tuple[str, str, str]]) -> None:
    shutil.copytree(RTL_DIR, target)
    for name, old, new in edits:
        path = target / name
        text = path.read_text(encoding="utf-8")
        if text.count(old) != 1:
            raise RuntimeError(f"mutation anchor not found exactly once in {name}: {old!r}")
        path.write_text(text.replace(old, new), encoding="utf-8")


def check_mutants(mutants: list[tuple[str, str, str, str]], core: str, n_random: int,
                  tmp: Path, first_number: int = 1) -> bool:
    """Run the suite on every mutant of one family; True if all are killed."""
    all_killed = True
    for offset, (desc, name, old, new) in enumerate(mutants):
        number = first_number + offset
        target = tmp / f"{core}_m{offset}"
        make_mutant(target, [(name, old, new)] + EXTRA_EDITS.get(desc, []))
        try:
            results = run_suite(target, n_random, core=core)
        except Exception as exc:  # e.g. the mutant does not compile
            print(f"[{number:2}] {desc}: suite error: {exc}")
            all_killed = False
            continue
        failed = [(group, case) for group, case, res in results
                  if not (isinstance(res, CosimResult) and res.ok)]
        by_group = {g: sum(1 for fg, _ in failed if fg == g) for g in ("program", "directed", "random")}
        totals = {g: sum(1 for rg, _, _ in results if rg == g) for g in ("program", "directed", "random")}
        if failed:
            first = failed[0][1]
            print(f"[{number:2}] KILLED   [{core}] {desc}\n"
                  f"       first caught by {first}; caught by "
                  f"{by_group['program']}/{totals['program']} programs, "
                  f"{by_group['directed']}/{totals['directed']} directed, "
                  f"{by_group['random']}/{totals['random']} random", flush=True)
        else:
            all_killed = False
            print(f"[{number:2}] SURVIVED [{core}] {desc}", flush=True)
    return all_killed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="inject bugs into copies of the RTL")
    parser.add_argument("--core", choices=("single", "multi", "both"), default="both",
                        help="mutant family: single-cycle datapath, multicycle FSM, or both (default)")
    parser.add_argument("--random", type=int, default=250, help="random programs per mutant")
    args = parser.parse_args(argv)

    all_killed = True
    with tempfile.TemporaryDirectory(prefix="mutants_") as tmp:
        number = 1
        if args.core in ("single", "both"):
            all_killed &= check_mutants(MUTANTS, "single", args.random, Path(tmp), number)
            number += len(MUTANTS)
        if args.core in ("multi", "both"):
            all_killed &= check_mutants(MULTI_MUTANTS, "multi", args.random, Path(tmp), number)
    print("all mutants killed" if all_killed else "some mutants survived")
    return 0 if all_killed else 1


if __name__ == "__main__":
    sys.exit(main())
