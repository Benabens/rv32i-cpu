# =============================================================================
# mandelbrot.s -- ASCII-art Mandelbrot set in fixed point, without a multiplier
# =============================================================================
#
# What it computes
#   A 78 x 33 character picture of the Mandelbrot set M, the set of complex
#   numbers c for which the sequence z0 = 0, z(k+1) = z(k)^2 + c stays
#   bounded. Each character is one sample point c = cx + i*cy:
#       cx = -2.1  + col * 37/1024      col = 0 .. 77   (x in [-2.1, 0.68])
#       cy = (row - 16) * 74/1024       row = 0 .. 32   (y in [-1.16, 1.16])
#   A character cell is about twice as tall as it is wide, hence dy = 2 dx.
#   The program then prints how many iterations it computed.
#
# Algorithm (escape time)
#   For each point, iterate with z = x + iy:
#       if |x| > 2 or |y| > 2: escape
#       x2 = x*x,  y2 = y*y
#       if x2 + y2 > 4: escape        (|z| > 2 guarantees divergence)
#       y  = 2*x*y + cy
#       x  = x2 - y2 + cx
#   at most 32 times. The first test is only a shortcut: |x| > 2 already
#   implies x2 > 4 (in Q22.10, 2049^2 / 1024 >= 4100 > 4096), so it never
#   changes the result, but it bounds every value that reaches a multiply.
#   The number n of completed iterations selects the character from a shade
#   table: points that escape at once are blank, slow escapers near the
#   boundary get dense characters, and points still bounded after 32
#   iterations (taken as members of M) are drawn with '@':
#       n     0-1  2  3  4  5-6  7-8  9-11  12-16  17-31  32
#       char       .  :  -   =    +     *     #      %    @
#
# Fixed-point format: Q22.10
#   A 32-bit two's complement word X represents X / 1024 (10 fractional bits,
#   resolution 2^-10 ~ 0.001). 4.0 is 4096, -2.1 is -2150, 37/1024 ~ 0.036.
#   A product of two Q22.10 numbers is (A*B) / 1024; it is TRUNCATED TOWARD
#   ZERO: the magnitude |A|*|B| is shifted right by 10 and the sign applied
#   afterwards. This makes mul(-a, b) = -mul(a, b) exactly, so the orbits of
#   c and of its conjugate are exact mirror images: the picture is exactly
#   symmetric about the real axis (row 16). The program uses this: it
#   computes rows 0..16 into a frame buffer and prints rows 17..32 as rows
#   15..0 again, which halves the work.
#
# Multiplication without a multiplier: quarter squares
#   RV32I has no mul instruction. Instead of a 32-step shift-and-add loop,
#   the program uses the identity (exact for integers, because a+b and a-b
#   have the same parity):
#       a*b = floor((a+b)^2 / 4) - floor((a-b)^2 / 4)
#   and a table Q[n] = floor(n^2 / 4) built once at start-up. A product then
#   costs two table loads, and a square a^2 = Q[2a] costs one. The table is
#   filled by additions only, using Q[n+1] = Q[n] + floor((n+1)/2).
#   Thanks to the |x|, |y| <= 2 test, every index is at most 2 * 2048, so the
#   table has 4097 entries.
#
# Memory layout
#   0x00000000  .text   code (167 instructions)
#   0x10000000  .data   strings, shade table (33 bytes), frame buffer of
#                       17 rows x 80 bytes (78 characters, "\n", NUL)
#   0x10001000          Q[] table: 4097 words = 16388 bytes, up to 0x10005004
#                       (inside the 64 KiB data RAM, which ends at 0x10010000)
#   0x7FFFFFF0  stack   one 48-byte frame for mandel
#
# Routines
#   build_squares()       fills Q[]                              (leaf)
#   fxmul(a0 = a, a1 = b) -> a0 = a*b / 1024, toward zero         (leaf)
#   mandel(a0 = cx, a1 = cy) -> a0 = n in 0..32                   (non-leaf:
#                         saves ra and s0-s10 on the stack, squares inline
#                         with one table load each, calls fxmul for x*y)
#
# CPU features exercised
#   nested loops and data-dependent branches (blt, beq, bne), jal / jalr
#   function calls with a stack frame, word loads (lw, table lookups), word
#   stores (sw, table fill), byte loads and stores (lbu shade table, sb frame
#   buffer), a halfword store (sh writes "\n\0" in one go), arithmetic
#   shifts for absolute values (srai / xor / sub), lui / auipc for addresses,
#   and the ecall print services (string, integer, exit).
# =============================================================================

        .text
        .globl  _start

_start:
        jal     build_squares

        la      a0, title
        li      a7, 4
        ecall

        # ---- compute rows 0..16 (cy <= 0) into the frame buffer -----------
        li      s0, 0               # s0 = row
        li      s2, -1184           # s2 = cy = (0 - 16) * 74
        li      s5, 0               # s5 = number of iterations computed
        la      s4, frame           # s4 = write pointer into the frame
row_loop:
        li      s1, 0               # s1 = col
        li      s3, -2150           # s3 = cx = -2.1 in Q22.10
col_loop:
        mv      a0, s3
        mv      a1, s2
        jal     mandel              # a0 = iterations before escape (0..32)
        add     s5, s5, a0
        la      t0, shades
        add     t0, t0, a0
        lbu     t1, 0(t0)           # character for this iteration count
        sb      t1, 0(s4)
        addi    s4, s4, 1
        addi    s3, s3, 37          # next column: cx += 37/1024
        addi    s1, s1, 1
        li      t0, 78
        bne     s1, t0, col_loop

        li      t0, 10              # '\n' followed by the NUL terminator:
        sh      t0, 0(s4)           # one halfword store (little-endian)
        addi    s4, s4, 2           # rows are 80 bytes apart

        addi    s2, s2, 74          # next row: cy += 74/1024
        addi    s0, s0, 1
        li      t0, 17
        bne     s0, t0, row_loop

        # ---- print rows 0..16, then 15..0 (the mirror image) --------------
        la      s4, frame
        li      s0, 17
print_down:
        mv      a0, s4
        li      a7, 4
        ecall
        addi    s4, s4, 80
        addi    s0, s0, -1
        bnez    s0, print_down
        addi    s4, s4, -160        # back to row 15
        li      s0, 16
print_up:
        mv      a0, s4
        li      a7, 4
        ecall
        addi    s4, s4, -80
        addi    s0, s0, -1
        bnez    s0, print_up

        la      a0, footer
        li      a7, 4
        ecall
        mv      a0, s5
        li      a7, 1
        ecall
        la      a0, footer2
        li      a7, 4
        ecall
        li      a7, 10
        ecall

# -----------------------------------------------------------------------------
# build_squares: Q[n] = floor(n^2 / 4) for n = 0 .. 4096, at 0x10001000
# -----------------------------------------------------------------------------
build_squares:
        lui     t0, 0x10001         # t0 = &Q[n]
        li      t1, 0               # t1 = n
        li      t2, 0               # t2 = Q[n]
        li      t3, 4097
bs_loop:
        sw      t2, 0(t0)
        addi    t1, t1, 1
        srli    t4, t1, 1           # floor((n+1) / 2)
        add     t2, t2, t4          # Q[n+1] = Q[n] + floor((n+1) / 2)
        addi    t0, t0, 4
        bne     t1, t3, bs_loop
        ret

# -----------------------------------------------------------------------------
# fxmul: a0 = a0 * a1 / 1024, truncated toward zero, for |a0| + |a1| <= 4096
#   |a|*|b| = Q[|a|+|b|] - Q[||a|-|b||], then shift, then apply the sign.
# -----------------------------------------------------------------------------
fxmul:
        xor     t3, a0, a1          # bit 31 = sign of the product
        srai    t0, a0, 31          # a0 = |a|
        xor     a0, a0, t0
        sub     a0, a0, t0
        srai    t0, a1, 31          # a1 = |b|
        xor     a1, a1, t0
        sub     a1, a1, t0
        add     t1, a0, a1          # t1 = |a| + |b|
        sub     t2, a0, a1          # t2 = ||a| - |b||
        srai    t0, t2, 31
        xor     t2, t2, t0
        sub     t2, t2, t0
        lui     t0, 0x10001
        slli    t1, t1, 2
        add     t1, t1, t0
        lw      t1, 0(t1)           # Q[|a| + |b|]
        slli    t2, t2, 2
        add     t2, t2, t0
        lw      t2, 0(t2)           # Q[||a| - |b||]
        sub     a0, t1, t2          # |a| * |b|, exact
        srli    a0, a0, 10
        srai    t3, t3, 31          # negate if the signs differ
        xor     a0, a0, t3
        sub     a0, a0, t3
        ret

# -----------------------------------------------------------------------------
# mandel: escape time of c = a0 + i*a1 (Q22.10), at most 32 iterations
#   Frame (48 bytes): 44 ra, 40 s0 = cx, 36 s1 = cy, 32 s2 = x, 28 s3 = y,
#     24 s4 = n, 20 s5 = x2, 16 s6 = y2, 12 s7 = 32 (iteration limit),
#     8 s8 = 2048 (2.0), 4 s9 = 4096 (4.0), 0 s10 = &Q[0]
# -----------------------------------------------------------------------------
mandel:
        addi    sp, sp, -48
        sw      ra, 44(sp)
        sw      s0, 40(sp)
        sw      s1, 36(sp)
        sw      s2, 32(sp)
        sw      s3, 28(sp)
        sw      s4, 24(sp)
        sw      s5, 20(sp)
        sw      s6, 16(sp)
        sw      s7, 12(sp)
        sw      s8, 8(sp)
        sw      s9, 4(sp)
        sw      s10, 0(sp)
        mv      s0, a0              # cx
        mv      s1, a1              # cy
        li      s2, 0               # x
        li      s3, 0               # y
        li      s4, 0               # n
        li      s7, 32
        li      s8, 2048
        li      s9, 4096
        lui     s10, 0x10001
m_loop:
        beq     s4, s7, m_done      # still bounded after 32 iterations
        srai    t0, s2, 31          # t1 = |x|
        xor     t1, s2, t0
        sub     t1, t1, t0
        blt     s8, t1, m_done      # |x| > 2: escaped
        srai    t0, s3, 31          # t2 = |y|
        xor     t2, s3, t0
        sub     t2, t2, t0
        blt     s8, t2, m_done      # |y| > 2: escaped
        slli    t0, t1, 3           # x2 = Q[2|x|] >> 10
        add     t0, t0, s10
        lw      s5, 0(t0)
        srli    s5, s5, 10
        slli    t0, t2, 3           # y2 = Q[2|y|] >> 10
        add     t0, t0, s10
        lw      s6, 0(t0)
        srli    s6, s6, 10
        add     t0, s5, s6
        blt     s9, t0, m_done      # |z|^2 > 4: escaped
        mv      a0, s2
        mv      a1, s3
        jal     fxmul               # a0 = x*y
        slli    a0, a0, 1
        add     s3, a0, s1          # y = 2xy + cy
        sub     s2, s5, s6
        add     s2, s2, s0          # x = x2 - y2 + cx
        addi    s4, s4, 1
        j       m_loop
m_done:
        mv      a0, s4
        lw      ra, 44(sp)
        lw      s0, 40(sp)
        lw      s1, 36(sp)
        lw      s2, 32(sp)
        lw      s3, 28(sp)
        lw      s4, 24(sp)
        lw      s5, 20(sp)
        lw      s6, 16(sp)
        lw      s7, 12(sp)
        lw      s8, 8(sp)
        lw      s9, 4(sp)
        lw      s10, 0(sp)
        addi    sp, sp, 48
        ret

        .data
title:
        .asciz  "Mandelbrot set on RV32I -- Q22.10 fixed point, no multiplier, 32 iterations max\n"
footer:
        .asciz  "iterations of z = z^2 + c computed: "
footer2:
        .asciz  " (lower half mirrored)\n"
shades:                             # character for n = 0 .. 32 iterations
        .ascii  "  .:-==++***#####%%%%%%%%%%%%%%%@"
        .align  2
frame:
        .space  1360                # 17 rows x 80 bytes
