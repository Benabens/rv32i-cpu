# =============================================================================
#  divide.s  -  unsigned 32-bit division by the restoring algorithm
# =============================================================================
#
#  WHAT IT COMPUTES
#    udiv(n, d) for unsigned 32-bit n (dividend) and d (divisor) returns
#        a0 = q = floor(n / d)      (quotient)
#        a1 = r = n - q*d           (remainder, 0 <= r < d)
#    the same results as the M-extension instructions divu and remu.
#
#  DIVISION BY ZERO  (defined behaviour, no trap)
#    For d = 0 the routine returns   q = 0xFFFFFFFF  and  r = n.
#    This is precisely what the RISC-V specification mandates for divu/remu
#    (RISC-V never traps on division by zero), and it is what the algorithm
#    below produces naturally: every trial subtraction of 0 "succeeds", so
#    every quotient bit is 1 and the dividend passes unchanged into the
#    remainder. No special case is needed; the tests check it explicitly.
#
#  ALGORITHM  (restoring division, one quotient bit per iteration)
#    Pencil-and-paper long division in base 2. The dividend bits are brought
#    down one at a time, most significant first, into a partial remainder R:
#        repeat 32 times:
#            R = 2*R + (next bit of n)
#            R = R - d                      (trial subtraction)
#            if R went negative:  R = R + d,  quotient bit = 0  (restore)
#            else:                            quotient bit = 1
#    Invariant: before each step R < d, so after the shift R < 2d and the
#    quotient bit is 0 or 1. In base 2 there is no "how many times does it
#    go" guess: the trial subtraction answers it.
#
#    Implementation details:
#    - n and the quotient share one register: n is shifted out on the left
#      while quotient bits are shifted in on the right.
#    - "R went negative" is detected as the unsigned borrow (R <u d),
#      computed with sltu BEFORE the subtraction.
#    - No 33rd bit is needed. One could fear that 2*R + bit overflows 32
#      bits when d > 2^31. It cannot: R never exceeds the number formed by
#      the dividend bits brought down so far (subtracting only makes it
#      smaller), and before the last shift at most 31 bits have been brought
#      down, so R < 2^31 and 2*R + 1 < 2^32. The tests check divisors above
#      2^31 explicitly.
#    (A "non-performing" variant compares first and subtracts only when
#    R >= d; it avoids the restore step. Both produce the same results.)
#
#  REGISTER CONVENTION
#    input : a0 = n (dividend, unsigned), a1 = d (divisor, unsigned)
#    output: a0 = quotient, a1 = remainder
#    uses  : t0-t2, t4-t5 (caller-saved); no stack
#
#  COURSE LINK
#    Binary long division and the sequential restoring divider (shift
#    register + subtractor + one quotient bit per clock cycle); unsigned
#    comparison through the borrow of a subtraction.
# =============================================================================

        .text
        .globl  udiv

udiv:
        mv      t0, a0              # t0: dividend bits, becomes the quotient
        li      t1, 0               # t1: partial remainder R
        li      t2, 32              # t2: iterations left
div_loop:
        slli    t1, t1, 1           # (R < 2^31 here: no bit is lost)
        srli    t4, t0, 31          # next dividend bit, MSB first
        or      t1, t1, t4          # R = 2*R + bit
        slli    t0, t0, 1           # free bit 0 for the quotient bit

        sltu    t5, t1, a1          # borrow of the trial subtraction
        sub     t1, t1, a1          # trial subtraction R - d
        bnez    t5, div_restore     # went negative: R was smaller than d
        ori     t0, t0, 1           # quotient bit = 1
        j       div_next
div_restore:
        add     t1, t1, a1          # undo the subtraction, quotient bit = 0
div_next:
        addi    t2, t2, -1
        bnez    t2, div_loop

        mv      a0, t0
        mv      a1, t1
        ret

# -----------------------------------------------------------------------------
#  Demo: 1000 / 7 = 142 remainder 6, and 1000 / 0 = 0xFFFFFFFF remainder
#        1000; prints "142 6" then "-1 1000".
# -----------------------------------------------------------------------------
        .globl  _start
_start:
        li      a0, 1000
        li      a1, 7
        call    udiv
        mv      s0, a0
        mv      s1, a1
        li      a0, 1000
        li      a1, 0
        call    udiv
        mv      s2, a0
        mv      s3, a1

        mv      a0, s0
        li      a7, 1
        ecall
        li      a0, ' '
        li      a7, 11
        ecall
        mv      a0, s1
        li      a7, 1
        ecall
        li      a0, '\n'
        li      a7, 11
        ecall
        mv      a0, s2
        li      a7, 1
        ecall
        li      a0, ' '
        li      a7, 11
        ecall
        mv      a0, s3
        li      a7, 1
        ecall
        li      a0, '\n'
        li      a7, 11
        ecall

        li      a7, 10
        ecall
