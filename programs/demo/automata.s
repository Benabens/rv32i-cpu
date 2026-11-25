# =============================================================================
# automata.s -- elementary cellular automata (rules 90 and 30), bit-parallel
# =============================================================================
#
# What it computes
#   A one-dimensional elementary cellular automaton is a row of cells, each 0
#   or 1. At every generation all cells are updated at once: the new value of
#   a cell is a fixed Boolean function of (left, centre, right) -- its own
#   value and its two neighbours'. The 8 possible neighbourhoods
#   k = 4*left + 2*centre + right give an 8-entry truth table, and the
#   "rule number" (Wolfram) is that truth table read as a byte: bit k of the
#   rule is the new state for neighbourhood k.
#
#   Starting from a single live cell, the program draws 32 generations of a
#   64-cell row ('#' = 1, blank = 0) for two rules and counts the live cells:
#     rule 90  = 0b01011010: new = left XOR right. Generation n is row n of
#                Pascal's triangle mod 2, so the picture is a Sierpinski
#                triangle; rows 0..31 hold 3^5 = 243 odd binomial coefficients.
#     rule 30  = 0b00011110: new = left XOR (centre OR right). Chaotic: its
#                centre column is irregular enough to be used as a random
#                number generator.
#
# Algorithm: one generation in a few dozen instructions, 32 cells at a time
#   The 64-cell row lives in a register pair (hi:lo), bit 63 = leftmost cell.
#   Shifting the whole row by one position aligns every cell with a neighbour:
#       L = row >> 1   (bit i of L = left neighbour of cell i)
#       R = row << 1   (bit i of R = right neighbour of cell i)
#   with the bit crossing between the two words carried by srli/slli/or, and
#   zeros entering at the edges (fixed dead boundary). The new row is then the
#   canonical sum of products of the truth table, evaluated with bitwise
#   operations on all 32 cells of a word in parallel:
#       new = OR over k with rule bit k set of  (L or ~L) & (C or ~C) & (R or ~R)
#   where each literal is complemented when the matching bit of k is 0. The
#   complement is a XOR with a mask (bit - 1) = 0 or all ones, so the loop
#   over the 8 minterms has no data-dependent branch except "is bit k set".
#   The engine never looks at which rule it runs: the rule number is data.
#   The seed is cell 31 from the left; in 32 generations a pattern grows by at
#   most 31 cells on each side, so it never touches the boundary.
#
# Memory layout
#   0x00000000  .text   code (140 instructions)
#   0x10000000  .data   strings, the table of rules to run (pairs of words:
#                       rule number, address of its description), and a
#                       68-byte row buffer
#   0x7FFFFFF0  stack   frames for run_rule (32 bytes) and _start's loop
#
# Routines
#   ca_step(a0 = hi, a1 = lo, a2 = rule) -> a0, a1 = next generation  (leaf)
#   print_row(a0 = hi, a1 = lo) -> a0 = live cells; prints the row, without
#                         trailing blanks                              (leaf)
#   run_rule(a0 = rule) -> a0 = total live cells over 32 generations
#                         (non-leaf: saves ra and s0-s4 on the stack)
#
# CPU features exercised
#   logic instructions (and, or, xor) and shifts by constants and by a
#   register (srl), multi-word shifts with the carried bit, loops and
#   branches (including bltz to test the top bit), byte stores and loads
#   (sb / lbu in the row buffer, scanned backwards to trim it), word loads
#   (lw of the rule table) and word stores / loads of saved registers,
#   jal / jalr function calls with stack frames, and the ecall print services.
# =============================================================================

        .text
        .globl  _start

_start:
        la      a0, title
        li      a7, 4
        ecall

        la      s0, rules           # s0 = pointer into the rule table
rule_loop:
        lw      s1, 0(s0)           # s1 = rule number (0 ends the table)
        beqz    s1, finish
        li      a0, 10              # blank line before each picture
        li      a7, 11
        ecall
        la      a0, msg_rule        # "Rule 90: ..."
        li      a7, 4
        ecall
        mv      a0, s1
        li      a7, 1
        ecall
        lw      a0, 4(s0)           # description of the rule
        li      a7, 4
        ecall

        mv      a0, s1
        jal     run_rule            # a0 = live cells in the picture
        li      a7, 1
        ecall
        la      a0, msg_live
        li      a7, 4
        ecall
        addi    s0, s0, 8
        j       rule_loop
finish:
        li      a7, 10
        ecall

# -----------------------------------------------------------------------------
# run_rule: draw 32 generations of `rule` from a single live cell
#   Frame (32 bytes): 28 ra, 24 s0 = rule, 20 s1 = hi, 16 s2 = lo,
#                     12 s3 = generations left, 8 s4 = live cells so far
# -----------------------------------------------------------------------------
run_rule:
        addi    sp, sp, -32
        sw      ra, 28(sp)
        sw      s0, 24(sp)
        sw      s1, 20(sp)
        sw      s2, 16(sp)
        sw      s3, 12(sp)
        sw      s4, 8(sp)
        mv      s0, a0
        li      s1, 1               # seed: bit 32 = cell 31 from the left
        li      s2, 0
        li      s3, 32
        li      s4, 0
rr_loop:
        mv      a0, s1
        mv      a1, s2
        jal     print_row
        add     s4, s4, a0
        mv      a0, s1
        mv      a1, s2
        mv      a2, s0
        jal     ca_step
        mv      s1, a0
        mv      s2, a1
        addi    s3, s3, -1
        bnez    s3, rr_loop
        mv      a0, s4
        lw      ra, 28(sp)
        lw      s0, 24(sp)
        lw      s1, 20(sp)
        lw      s2, 16(sp)
        lw      s3, 12(sp)
        lw      s4, 8(sp)
        addi    sp, sp, 32
        ret

# -----------------------------------------------------------------------------
# ca_step: next generation of the 64-cell row a0:a1 under rule a2
# -----------------------------------------------------------------------------
ca_step:
        srli    t0, a0, 1           # t0:t1 = L = row >> 1
        slli    t1, a0, 31
        srli    t2, a1, 1
        or      t1, t1, t2
        slli    t2, a0, 1           # t2:t3 = R = row << 1
        srli    t3, a1, 31
        or      t2, t2, t3
        slli    t3, a1, 1
        li      t4, 0               # t4:t5 = new row
        li      t5, 0
        li      t6, 7               # t6 = k, neighbourhood 7 down to 0
cs_loop:
        srl     a3, a2, t6          # bit k of the rule
        andi    a3, a3, 1
        beqz    a3, cs_next
        srli    a3, t6, 2           # left literal: L, or ~L if bit 2 of k is 0
        andi    a3, a3, 1
        addi    a3, a3, -1          # mask = 0 (keep) or -1 (complement)
        xor     a4, t0, a3
        xor     a5, t1, a3
        srli    a3, t6, 1           # centre literal
        andi    a3, a3, 1
        addi    a3, a3, -1
        xor     a6, a0, a3
        and     a4, a4, a6
        xor     a6, a1, a3
        and     a5, a5, a6
        andi    a3, t6, 1           # right literal
        addi    a3, a3, -1
        xor     a6, t2, a3
        and     a4, a4, a6
        xor     a6, t3, a3
        and     a5, a5, a6
        or      t4, t4, a4          # add the minterm to the sum of products
        or      t5, t5, a5
cs_next:
        addi    t6, t6, -1
        bgez    t6, cs_loop
        mv      a0, t4
        mv      a1, t5
        ret

# -----------------------------------------------------------------------------
# print_row: print the row a0:a1 ('#' = live), return the number of live cells
# -----------------------------------------------------------------------------
print_row:
        la      t0, rowbuf          # t0 = write pointer
        li      t1, 0               # t1 = live cells
        li      t4, '#'
        li      t5, ' '
        mv      t2, a0              # first the high word, then the low word
        li      t6, 2
pr_word:
        li      t3, 32
pr_bit:
        bltz    t2, pr_live         # top bit = current cell
        sb      t5, 0(t0)
        j       pr_adv
pr_live:
        sb      t4, 0(t0)
        addi    t1, t1, 1
pr_adv:
        addi    t0, t0, 1
        slli    t2, t2, 1
        addi    t3, t3, -1
        bnez    t3, pr_bit
        mv      t2, a1
        addi    t6, t6, -1
        bnez    t6, pr_word
        la      t2, rowbuf          # trim trailing blanks
pr_trim:
        beq     t0, t2, pr_end
        lbu     t3, -1(t0)
        bne     t3, t5, pr_end
        addi    t0, t0, -1
        j       pr_trim
pr_end:
        li      t3, 10
        sb      t3, 0(t0)
        sb      zero, 1(t0)
        mv      a0, t2
        li      a7, 4
        ecall
        mv      a0, t1
        ret

        .data
title:
        .asciz  "Elementary cellular automata on RV32I -- 64 cells, 32 generations, bit-parallel\n"
msg_rule:
        .asciz  "Rule "
msg_live:
        .asciz  " live cells\n"
desc90:
        .asciz  ": new cell = left XOR right  (Pascal's triangle mod 2)\n"
desc30:
        .asciz  ": new cell = left XOR (centre OR right)\n"
        .align  2
rules:                              # rule number, description; 0 = end
        .word   90, desc90
        .word   30, desc30
        .word   0, 0
rowbuf:
        .space  68                  # 64 cells + "\n" + NUL, rounded up
