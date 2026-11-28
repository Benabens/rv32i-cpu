# =============================================================================
#  rotate.s  -  rotate a 32-bit word left or right by n positions
# =============================================================================
#
#  WHAT IT COMPUTES
#    rotl(x, n): the bits of x shifted left by n, the n bits that fall off
#                the top re-entering at the bottom.
#    rotr(x, n): the same towards the right.
#    Only n mod 32 matters (rotating by 32 is the identity), so n may be any
#    value, including negative ones: rotl(x, -1) = rotr(x, 1).
#        rotl(0x80000001, 1) = 0x00000003
#        rotr(0x80000001, 1) = 0xC0000000
#
#  ALGORITHM
#    RV32I has shifts but no rotate (that comes with the Zbb extension).
#    A rotation is the OR of two shifts that move the two parts of the word:
#        rotl(x, n) = (x << n) | (x >> (32 - n))      (logical shifts)
#    RISC-V shift instructions only look at the low 5 bits of the shift
#    amount register, so:
#      - n is reduced modulo 32 for free;
#      - (32 - n) mod 32 = (-n) mod 32, so "neg" gives the second amount
#        directly;
#      - for n = 0 the second shift is x >> 0 = x, and x | x = x: the
#        identity comes out right without a special case.
#    srl (logical, not sra) is mandatory: an arithmetic shift would copy the
#    sign bit into the vacated positions and corrupt the result.
#
#  REGISTER CONVENTION
#    rotl / rotr
#    input : a0 = x, a1 = n (only bits 4..0 are used)
#    output: a0 = rotated word
#    uses  : t0-t1 (caller-saved); no stack
#
#  COURSE LINK
#    Logical versus arithmetic shifts, shift amounts as 5-bit fields, and the
#    rotator / barrel shifter found in ALUs. Rotations are the basic mixing
#    step of many hash functions and ciphers (SHA-2, ChaCha).
# =============================================================================

        .text
        .globl  rotl
        .globl  rotr

rotl:
        sll     t0, a0, a1          # x << (n mod 32)
        neg     t1, a1              # (32 - n) mod 32 in the low 5 bits
        srl     t1, a0, t1          # bits that wrapped around
        or      a0, t0, t1
        ret

rotr:
        srl     t0, a0, a1          # x >> (n mod 32), zero-filled
        neg     t1, a1
        sll     t1, a0, t1          # bits that wrapped around
        or      a0, t0, t1
        ret

# -----------------------------------------------------------------------------
#  Demo: rotl(0x80000001, 1) = 3, rotr(0x80000001, 1) = 0xC0000000;
#        prints "3 -1073741824".
# -----------------------------------------------------------------------------
        .globl  _start
_start:
        li      a0, 0x80000001
        li      a1, 1
        call    rotl
        mv      s0, a0
        li      a0, 0x80000001
        li      a1, 1
        call    rotr
        mv      s1, a0

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

        li      a7, 10
        ecall
