# =============================================================================
#  byte_swap.s  -  reverse the byte order of a 32-bit word (endianness swap)
# =============================================================================
#
#  WHAT IT COMPUTES
#    Bytes (B3 B2 B1 B0), B3 most significant, become (B0 B1 B2 B3):
#        byte_swap(0x11223344) = 0x44332211
#    This converts a word between little-endian and big-endian layout.
#
#  WHY IT MATTERS
#    RISC-V is little-endian: "sw" stores B0 at the lowest address. Network
#    protocols and many file formats are big-endian (B3 first). A word read
#    from such a buffer with "lw" has its bytes in the wrong order and must
#    be swapped (htonl / ntohl in C). Applying the swap twice gives back the
#    original word.
#
#  ALGORITHM
#    Each byte moves by a fixed distance:
#        B0: left 24     B3: right 24     (shifts alone isolate them)
#        B1: left  8     B2: right  8     (need the mask 0x0000FF00)
#    The four pieces do not overlap, so they are combined with OR.
#    Logical shifts (srli) bring in zeros; srai would smear the sign bit.
#
#  REGISTER CONVENTION
#    input : a0 = x
#    output: a0 = x with its four bytes in reverse order
#    uses  : t0-t2 (caller-saved); no stack
#
#  COURSE LINK
#    Memory organisation: byte addressing and endianness in the RISC-V
#    memory model; masks and shifts to extract and insert bit fields.
# =============================================================================

        .text
        .globl  byte_swap

byte_swap:
        slli    t0, a0, 24          # B0 -> bits 31..24 (everything else gone)
        srli    t1, a0, 24          # B3 -> bits  7..0
        or      t0, t0, t1

        li      t2, 0x0000FF00      # mask for bits 15..8
        srli    t1, a0, 8
        and     t1, t1, t2          # B2 -> bits 15..8
        or      t0, t0, t1

        and     t1, a0, t2
        slli    t1, t1, 8           # B1 -> bits 23..16
        or      a0, t0, t1
        ret

# -----------------------------------------------------------------------------
#  Demo: store 0x11223344 in memory, show that the first byte in memory is
#  0x44 (little-endian), then byte_swap it: the first byte becomes 0x11.
#  Prints "68 17 1144201745" (0x44, 0x11, 0x44332211).
# -----------------------------------------------------------------------------
        .data
demo_word:
        .word   0

        .text
        .globl  _start
_start:
        la      s0, demo_word
        li      a0, 0x11223344
        sw      a0, 0(s0)
        lbu     s1, 0(s0)           # lowest address holds the LOW byte: 0x44
        call    byte_swap
        mv      s3, a0
        sw      a0, 0(s0)
        lbu     s2, 0(s0)           # after the swap: 0x11

        mv      a0, s1
        li      a7, 1
        ecall
        li      a0, ' '
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
