"""Random instruction-stream programs for co-simulation.

Each program is generated from a seed, so a failing case can always be
reproduced with ``python3 sim/random_programs.py <seed>``.  A program:

1. fills every register with a random value (edge values such as 0, -1,
   INT_MIN and INT_MAX are favoured) and points ``s11`` (x27) at the middle
   of a 256-byte data buffer initialised with random words;
2. executes a stream of random instructions:
   * register-register and register-immediate ALU operations on random
     registers (including x0 as a destination), shifts with every amount,
     ``lui`` / ``auipc``;
   * loads and stores of every width (``lb lbu lh lhu lw sb sh sw``) at every
     legal alignment, with positive and negative offsets from ``s11``;
   * forward conditional branches of every kind, forward ``jal`` and
     ``auipc``+``jalr`` jumps (sometimes with an odd offset, so that the
     hardware must clear bit 0 of the jalr target);
3. prints a few registers and a string through ``ecall`` and stops in one of
   three ways: exit ecall (code from a register), ``ebreak``, or by running
   off the end of ``.text``.

``s11`` is never a destination, so every memory access stays inside the
buffer and is properly aligned: the programs never trap.  Branches only go
forward, so every program terminates.
"""

from __future__ import annotations

import random
import sys

BASE = 27                       # s11: buffer pointer, never written by the stream
BUF_BYTES = 256
WRITABLE = [r for r in range(32) if r != BASE]

R_OPS = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
I_OPS = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SHIFT_OPS = ["slli", "srli", "srai"]
BRANCHES = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
LOADS = {"lb": 1, "lbu": 1, "lh": 2, "lhu": 2, "lw": 4}
STORES = {"sb": 1, "sh": 2, "sw": 4}

EDGE_VALUES = [0, 1, -1, 2, -2, 0x7FFFFFFF, -0x80000000, 0x80000001 - (1 << 32),
               0xFF, 0xFFFF, 0x8000, 0x80, 31, 32, 0x55555555, -0x55555556]
EDGE_IMMS = [0, 1, -1, 2047, -2048, 0x7FF, 0x800 - 4096, 31, 32, 0xFF, -0x80]


class _Generator:
    def __init__(self, seed: int, length: int) -> None:
        self.rng = random.Random(seed)
        self.seed = seed
        self.length = length
        self.lines: list[str] = []
        self.pending: list[list] = []   # [label, instructions left before it]
        self.label_count = 0

    # ---- random operands -------------------------------------------------
    def value(self) -> int:
        rng = self.rng
        if rng.random() < 0.3:
            return rng.choice(EDGE_VALUES)
        return rng.randrange(-(1 << 31), 1 << 31)

    def imm12(self) -> int:
        rng = self.rng
        return rng.choice(EDGE_IMMS) if rng.random() < 0.3 else rng.randrange(-2048, 2048)

    def rd(self) -> str:
        # x0 as destination from time to time: the write must be discarded.
        return "x0" if self.rng.random() < 0.05 else f"x{self.rng.choice(WRITABLE)}"

    def rs(self) -> str:
        return f"x{self.rng.randrange(32)}"

    # ---- emission --------------------------------------------------------
    def emit(self, text: str) -> None:
        """Emit one instruction, then place the labels whose distance ran out."""
        self.lines.append(f"        {text}")
        for item in self.pending:
            item[1] -= 1
        for item in [p for p in self.pending if p[1] <= 0]:
            self.lines.append(f"{item[0]}:")
            self.pending.remove(item)

    def new_label(self, distance: int) -> str:
        self.label_count += 1
        label = f"L{self.label_count}"
        self.pending.append([label, distance])
        return label

    def alu(self) -> None:
        rng = self.rng
        kind = rng.random()
        if kind < 0.45:
            self.emit(f"{rng.choice(R_OPS)} {self.rd()}, {self.rs()}, {self.rs()}")
        elif kind < 0.80:
            self.emit(f"{rng.choice(I_OPS)} {self.rd()}, {self.rs()}, {self.imm12()}")
        elif kind < 0.92:
            self.emit(f"{rng.choice(SHIFT_OPS)} {self.rd()}, {self.rs()}, {rng.randrange(32)}")
        else:
            op = rng.choice(["lui", "auipc"])
            self.emit(f"{op} {self.rd()}, 0x{rng.randrange(1 << 20):x}")

    def memory_offset(self, size: int) -> int:
        # s11 points at buf + 128: offsets in [-128, 128 - size], multiples of size.
        return self.rng.randrange(-128 // size, (128 - size) // size + 1) * size

    def instruction(self) -> None:
        rng = self.rng
        kind = rng.random()
        if kind < 0.50:
            self.alu()
        elif kind < 0.66:
            op = rng.choice(list(LOADS))
            self.emit(f"{op} {self.rd()}, {self.memory_offset(LOADS[op])}(x{BASE})")
        elif kind < 0.80:
            op = rng.choice(list(STORES))
            self.emit(f"{op} {self.rs()}, {self.memory_offset(STORES[op])}(x{BASE})")
        elif kind < 0.93:
            label = self.new_label(rng.randint(1, 4))
            self.emit(f"{rng.choice(BRANCHES)} {self.rs()}, {self.rs()}, {label}")
        elif kind < 0.97:
            label = self.new_label(rng.randint(1, 4))
            self.emit(f"jal {self.rd()}, {label}")
        else:
            # auipc t, 0 ; jalr rd, off(t) jumps over `skip` filler instructions.
            # An odd offset checks that the hardware clears bit 0 of the target.
            skip = rng.randint(0, 3)
            offset = 8 + 4 * skip + (1 if rng.random() < 0.5 else 0)
            temp = rng.choice([r for r in WRITABLE if r != 0])
            # No label may fall between the two (a branch landing on the jalr
            # would jump through a stale register), so auipc bypasses emit().
            self.lines.append(f"        auipc x{temp}, 0")
            self.emit(f"jalr {self.rd()}, {offset}(x{temp})")
            for _ in range(skip):
                self.emit(f"{rng.choice(R_OPS)} {self.rd()}, {self.rs()}, {self.rs()}")

    def generate(self) -> str:
        rng = self.rng
        words = ", ".join(f"0x{rng.randrange(1 << 32):08x}" for _ in range(BUF_BYTES // 4))
        out = [
            f"# random instruction stream, seed {self.seed}",
            "        .data",
            f"buf:    .word {words}",
            'msg:    .asciz "|end\\n"',
            "        .text",
            "_start:",
        ]
        self.lines = out
        for r in WRITABLE[1:]:
            self.lines.append(f"        li x{r}, {self.value()}")
        self.lines.append(f"        la x{BASE}, buf")
        self.lines.append(f"        addi x{BASE}, x{BASE}, 128")

        for _ in range(self.length):
            self.instruction()
        while self.pending:                      # land the last forward branches
            self.emit("addi x0, x0, 0")

        # Epilogue: print three registers separated by spaces, then a string.
        for _ in range(3):
            self.emit(f"mv a0, x{rng.choice(WRITABLE)}")
            self.emit("li a7, 1")
            self.emit("ecall")
            self.emit("li a0, 32")
            self.emit("li a7, 11")
            self.emit("ecall")
        self.emit("la a0, msg")
        self.emit("li a7, 4")
        self.emit("ecall")
        ending = rng.random()
        if ending < 0.4:
            self.emit(f"mv a0, x{rng.choice(WRITABLE)}")
            self.emit("li a7, 93")
            self.emit("ecall")
        elif ending < 0.5:
            self.emit("ebreak")
        # else: fall off the end of .text
        return "\n".join(self.lines) + "\n"


def generate(seed: int, length: int = 200) -> str:
    """Assembly source of the random program for ``seed``."""
    return _Generator(seed, length).generate()


if __name__ == "__main__":
    sys.stdout.write(generate(int(sys.argv[1]) if len(sys.argv) > 1 else 0))
