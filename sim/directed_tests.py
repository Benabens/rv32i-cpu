"""Small hand-written programs for the corners the demo programs never reach.

Each entry maps a name to assembly source.  They are co-simulated like the
other programs; the trap cases check that the hardware stops on the same
instruction, with the same cause, as the reference simulator.
"""

# Instruction limit for tests that are meant to hit it.
MAX_STEPS: dict[str, int] = {"timeout_infinite_loop": 5000}

DIRECTED: dict[str, str] = {
    # x0 ignores writes from every kind of instruction; x0 is read back
    # after each write so that a single leaked write is visible.
    "x0_is_zero": """
        li   t0, 123
        li   t1, 0
        addi x0, t0, 1
        or   t1, t1, x0
        lui  x0, 0xfffff
        or   t1, t1, x0
        jal  x0, 4
        or   t1, t1, x0
        lw   x0, 0(sp)
        or   t1, t1, x0
        mv   a0, t1
        li   a7, 1
        ecall
    """,
    # Jumps and branches with offsets beyond +-2 KiB exercise the high
    # immediate bits (J-type bits 19:11, B-type bit 11), which the small
    # demo programs never set.
    "far_jumps_and_branches": """
        li   s0, 0
        jal  ra, far_forward
    back:
        addi s0, s0, 100
        beq  x0, x0, far_branch
        .space 3000
    far_forward:
        addi s0, s0, 1
        jal  x0, back
        .space 800
    far_branch:
        addi s0, s0, 10
        mv   a0, s0
        li   a7, 1
        ecall
    """,
    # Every load width from data that has the sign bit set in every byte.
    "load_extension": """
        .data
    v:  .word 0x80ff7f81
        .text
        la   s0, v
        lb   a0, 0(s0)
        lb   a1, 1(s0)
        lb   a2, 2(s0)
        lb   a3, 3(s0)
        lbu  a4, 3(s0)
        lh   a5, 0(s0)
        lh   a6, 2(s0)
        lhu  t0, 2(s0)
        lw   t1, 0(s0)
    """,
    # Loads from the instruction ROM read the machine code.
    "load_from_text": """
        la   t0, here
    here:
        lw   a0, 0(t0)
        lhu  a1, 2(t0)
        lbu  a2, 1(t0)
    """,
    # fence is a no-op; ebreak stops the machine.
    "fence_and_ebreak": """
        li    a0, 5
        fence
        addi  a0, a0, 1
        ebreak
        li    a0, 99
    """,
    # lui/auipc with the top bit set, and jalr with an odd target.
    "upper_and_jalr": """
        lui   t0, 0x80000
        auipc t1, 0xfffff
        la    t2, target
        addi  t2, t2, 1
        jalr  ra, 0(t2)
        li    a0, 1
    target:
        li    a0, 2
    """,
    # exit with a negative code through service 93.
    "exit_negative": """
        li  a0, -7
        li  a7, 93
        ecall
    """,
    # ---- traps: the faulting instruction must not retire ----
    "trap_misaligned_load": """
        li  t0, 0x10000002
        li  t1, 42
        lw  t1, 0(t0)
    """,
    "trap_misaligned_store": """
        li  t0, 0x10000001
        sh  t0, 0(t0)
    """,
    "trap_misaligned_jump": """
        li   t1, 7
        beq  x0, x0, 6
        nop
    """,
    "trap_illegal_instruction": """
        li    t0, 1
        .word 0xffffffff
    """,
    "trap_bad_ecall": """
        li  a7, 77
        ecall
    """,
    "trap_jump_outside_text": """
        li  t0, 0x2000
        jr  t0
    """,
    "timeout_infinite_loop": """
    spin:
        addi t0, t0, 1
        j    spin
    """,
}

# Reserved encodings next to real instructions: each must trap as illegal in
# both models (this checks that the hardware decoder's legality rules match
# rvsim's).  The word is preceded by one valid instruction.
ILLEGAL_WORDS: dict[str, int] = {
    "csrrw (SYSTEM, funct3 = 001)": 0x30029073,
    "ecall with rd != 0": 0x000000F3,
    "fence.i (MISC-MEM, funct3 = 001)": 0x0000100F,
    "xor with funct7 = 0100000": 0x40C5C533,
    "add with funct7 = 0000001 (M extension mul)": 0x02C58533,
    "slli with funct7 = 0100000": 0x40159513,
    "srli with funct7 = 0000001": 0x0215D513,
    "load funct3 = 011 (ld)": 0x0005B503,
    "store funct3 = 011 (sd)": 0x00A5B023,
    "branch funct3 = 010": 0x00B52063,
    "jalr funct3 = 001": 0x000590E7,
    "all-zero word": 0x00000000,
}

for _name, _word in ILLEGAL_WORDS.items():
    DIRECTED[f"illegal: {_name}"] = f"""
        li    a0, 1
        .word 0x{_word:08x}
    """
