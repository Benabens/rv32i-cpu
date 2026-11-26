# =============================================================================
#  add64.s  -  64-bit addition and subtraction on a 32-bit machine
# =============================================================================
#
#  WHAT IT COMPUTES
#    A 64-bit value is held in a register PAIR, high word : low word
#    (the convention used by the RISC-V ABI for 64-bit integers on RV32).
#        add64(a1:a0, a3:a2) = a1:a0 + a3:a2   (mod 2^64), result in a1:a0
#        sub64(a1:a0, a3:a2) = a1:a0 - a3:a2   (mod 2^64), result in a1:a0
#    Because two's complement arithmetic is the same for signed and unsigned
#    numbers, both routines are correct for signed and unsigned 64-bit
#    integers alike.
#
#  ALGORITHM  (multi-word arithmetic)
#    Add the low words; the carry out of bit 31 must be added to the high
#    words. RISC-V has no carry flag, but the carry can be recomputed:
#        lo = a_lo + b_lo  (mod 2^32)
#        carry = 1  iff  the true sum >= 2^32  iff  lo <u a_lo
#    (if the addition wrapped, the result is smaller than either operand;
#    if it did not wrap, it is at least as large as both). One sltu does it.
#        hi = a_hi + b_hi + carry
#    Subtraction is symmetrical: a borrow is needed from the high word when
#    a_lo <u b_lo, so  hi = a_hi - b_hi - borrow.
#    Any carry out of the high word is the overflow of the 64-bit operation
#    and is discarded (wrap-around modulo 2^64).
#
#  REGISTER CONVENTION
#    add64 / sub64
#    input : a1:a0 = first operand (a1 high, a0 low)
#            a3:a2 = second operand (a3 high, a2 low)
#    output: a1:a0 = result
#    uses  : t0-t1 (caller-saved); no stack
#
#  COURSE LINK
#    Binary addition with carry propagation: chaining two 32-bit adders
#    through the carry is exactly how wider ripple-carry adders are built
#    from smaller blocks. Carry detection by unsigned comparison.
# =============================================================================

        .text
        .globl  add64
        .globl  sub64

add64:
        add     t0, a0, a2          # low word (may wrap)
        sltu    t1, t0, a0          # carry out of the low word
        add     a1, a1, a3          # high words
        add     a1, a1, t1          # plus the carry
        mv      a0, t0
        ret

sub64:
        sltu    t1, a0, a2          # borrow: a_lo < b_lo (unsigned)
        sub     a0, a0, a2          # low word (may wrap)
        sub     a1, a1, a3          # high words
        sub     a1, a1, t1          # minus the borrow
        ret

# -----------------------------------------------------------------------------
#  Demo: 0x00000001_FFFFFFFF + 0x00000000_00000001 = 0x00000002_00000000
#        (the carry crosses the word boundary), then subtract it back.
#  Prints "2 0" (high, low) then "1 -1".
# -----------------------------------------------------------------------------
        .globl  _start
_start:
        li      a0, 0xFFFFFFFF      # first operand, low
        li      a1, 1               # first operand, high
        li      a2, 1               # second operand, low
        li      a3, 0               # second operand, high
        call    add64
        mv      s0, a0              # low  = 0
        mv      s1, a1              # high = 2
        li      a2, 1
        li      a3, 0
        call    sub64
        mv      s2, a0              # low  = 0xFFFFFFFF
        mv      s3, a1              # high = 1

        mv      a0, s1
        li      a7, 1
        ecall
        li      a0, ' '
        li      a7, 11
        ecall
        mv      a0, s0
        li      a7, 1
        ecall
        li      a0, '\n'
        li      a7, 11
        ecall
        mv      a0, s3
        li      a7, 1
        ecall
        li      a0, ' '
        li      a7, 11
        ecall
        mv      a0, s2
        li      a7, 1
        ecall
        li      a0, '\n'
        li      a7, 11
        ecall

        li      a7, 10
        ecall
