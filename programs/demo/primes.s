# =============================================================================
# primes.s -- Sieve of Eratosthenes over a byte array, printed as a table
# =============================================================================
#
# What it computes
#   All prime numbers up to N = 2000, printed right-aligned in a table of
#   15 columns, followed by their count (303) and the largest one (1999).
#
# Algorithm
#   1. sieve: a byte array flag[0..N] starts at zero ("maybe prime").
#      For p = 2, 3, ... while p*p <= N: if flag[p] is still 0, p is prime,
#      and every multiple p*p, p*p + p, p*p + 2p, ... <= N is crossed out
#      (flag = 1). Smaller multiples k*p with k < p were already crossed out
#      by the prime factors of k. RV32I has no multiplier, and none is
#      needed: p*p is maintained incrementally with (p+1)^2 = p^2 + 2p + 1,
#      and the multiples are reached by repeated addition of p.
#   2. collect: scan flag[2..N] and append each prime to an array of
#      halfwords (every prime below 65536 fits in 16 bits). The number of
#      entries is the prime count.
#   3. print: walk the halfword array; each number is printed in a field of
#      5 characters. The padding is found by comparing with 10, 100, 1000 --
#      no division -- and the digits are printed by the integer ecall.
#
# Memory layout
#   0x00000000  .text   code (119 instructions)
#   0x10000000  .data   strings
#               flag    N + 1 = 2001 bytes, zero-initialised (.space)
#               primes  room for 512 halfwords (pi(2000) = 303)
#   0x7FFFFFF0  stack   16-byte frames for collect and print_table
#
# Routines
#   sieve(a0 = flag, a1 = N)                                (leaf)
#   collect(a0 = flag, a1 = N, a2 = primes) -> a0 = count   (leaf)
#   print_padded(a0 = value)    prints value in a 5-character field (leaf)
#   print_table(a0 = primes, a1 = count)   non-leaf: saves ra, s0-s2 on the
#                               stack and calls print_padded for each entry
#
# CPU features exercised
#   nested loops with data-dependent exits, byte stores and loads (sb / lbu on
#   the flag array), halfword stores and loads (sh / lhu on the prime list),
#   word stores and loads (sw / lw of the saved registers), function calls
#   (jal / jalr) with a stack frame, signed and unsigned compares
#   (blt, bltu, bgeu), and the ecall print services.
# =============================================================================

        .text
        .globl  _start

_start:
        la      a0, title
        li      a7, 4
        ecall

        la      a0, flag
        li      a1, 2000
        jal     sieve

        la      a0, flag
        li      a1, 2000
        la      a2, primes
        jal     collect
        mv      s0, a0              # s0 = number of primes

        la      a0, primes
        mv      a1, s0
        jal     print_table

        mv      a0, s0              # "303 primes up to 2000, the largest is 1999"
        li      a7, 1
        ecall
        la      a0, msg_count
        li      a7, 4
        ecall
        la      t0, primes          # largest = primes[count - 1]
        slli    t1, s0, 1
        add     t0, t0, t1
        lhu     a0, -2(t0)
        li      a7, 1
        ecall
        li      a0, 10
        li      a7, 11
        ecall
        li      a7, 10
        ecall

# -----------------------------------------------------------------------------
# sieve: cross out the composites of flag[0..N] (flag[k] = 1 if k composite)
#   a0 = flag (all zero on entry), a1 = N
# -----------------------------------------------------------------------------
sieve:
        li      t0, 2               # t0 = p
        li      t1, 4               # t1 = p*p
sv_outer:
        bltu    a1, t1, sv_done     # stop when p*p > N
        add     t2, a0, t0
        lbu     t3, 0(t2)
        bnez    t3, sv_next         # p already crossed out: not prime
        add     t2, a0, t1          # t2 = &flag[p*p]
        add     t4, a0, a1          # t4 = &flag[N]
        li      t5, 1
sv_cross:
        sb      t5, 0(t2)           # flag[m] = 1 for m = p*p, p*p + p, ...
        add     t2, t2, t0
        bgeu    t4, t2, sv_cross    # while &flag[m] <= &flag[N]
sv_next:
        add     t1, t1, t0          # (p+1)^2 = p^2 + 2p + 1
        add     t1, t1, t0
        addi    t1, t1, 1
        addi    t0, t0, 1
        j       sv_outer
sv_done:
        ret

# -----------------------------------------------------------------------------
# collect: store every k in 2..N with flag[k] == 0 as a halfword in primes[]
#   a0 = flag, a1 = N, a2 = primes  ->  a0 = number of primes stored
# -----------------------------------------------------------------------------
collect:
        mv      t0, a2              # t0 = write pointer
        li      t1, 2               # t1 = k
cl_loop:
        blt     a1, t1, cl_done
        add     t2, a0, t1
        lbu     t3, 0(t2)
        bnez    t3, cl_skip
        sh      t1, 0(t0)
        addi    t0, t0, 2
cl_skip:
        addi    t1, t1, 1
        j       cl_loop
cl_done:
        sub     a0, t0, a2          # bytes written ...
        srli    a0, a0, 1           # ... / 2 = number of halfwords
        ret

# -----------------------------------------------------------------------------
# print_padded: print a0 (0 <= a0 < 100000) right-aligned in 5 characters
# -----------------------------------------------------------------------------
print_padded:
        mv      t0, a0
        li      t1, 4               # t1 = spaces = 5 - number of digits
        li      t2, 10
pp_digits:
        bltu    t0, t2, pp_pad      # value < 10^k: it has k digits
        addi    t1, t1, -1
        slli    t3, t2, 3           # 10^(k+1) = 8 * 10^k + 2 * 10^k
        slli    t2, t2, 1
        add     t2, t2, t3
        bnez    t1, pp_digits
pp_pad:
        li      a0, ' '
        li      a7, 11
pp_space:
        beqz    t1, pp_number
        ecall
        addi    t1, t1, -1
        j       pp_space
pp_number:
        mv      a0, t0
        li      a7, 1
        ecall
        ret

# -----------------------------------------------------------------------------
# print_table: print count halfwords from a0, 15 per line
#   Frame (16 bytes): 12 ra, 8 s0 = pointer, 4 s1 = remaining, 0 s2 = column
# -----------------------------------------------------------------------------
print_table:
        addi    sp, sp, -16
        sw      ra, 12(sp)
        sw      s0, 8(sp)
        sw      s1, 4(sp)
        sw      s2, 0(sp)
        mv      s0, a0
        mv      s1, a1
        li      s2, 0
pt_loop:
        beqz    s1, pt_end
        lhu     a0, 0(s0)
        jal     print_padded
        addi    s0, s0, 2
        addi    s1, s1, -1
        addi    s2, s2, 1
        li      t0, 15
        bne     s2, t0, pt_loop
        li      s2, 0               # end of a full line
        li      a0, 10
        li      a7, 11
        ecall
        j       pt_loop
pt_end:
        beqz    s2, pt_ret          # finish a partial last line
        li      a0, 10
        li      a7, 11
        ecall
pt_ret:
        lw      ra, 12(sp)
        lw      s0, 8(sp)
        lw      s1, 4(sp)
        lw      s2, 0(sp)
        addi    sp, sp, 16
        ret

        .data
title:
        .asciz  "Sieve of Eratosthenes on RV32I -- all primes up to 2000\n"
msg_count:
        .asciz  " primes up to 2000, the largest is "
flag:
        .space  2001                # flag[k] = 1 once k is known composite
        .align  1
primes:
        .space  1024                # up to 512 halfwords
