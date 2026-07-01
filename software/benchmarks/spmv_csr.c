/* software/benchmarks/spmv_csr.c
 *
 * Sparse Matrix-Vector Multiply (SpMV) in Compressed Sparse Row (CSR) format.
 *
 * Primary baseline benchmark for FluxCore sparse-computing research.
 *
 * All matrix data is initialized via direct assignment so the compiler emits
 * ADDI+SW sequences (immediates embedded in .text).  This avoids rodata and
 * memcpy — both of which require data accessible via the DMEM bus, which
 * constant arrays in .rodata would not be (Harvard architecture: IMEM is only
 * reachable by the instruction fetch unit, not by LOAD instructions).
 *
 * Matrix: 8×8 synthetic sparse, NNZ=21 (~33% fill), integer arithmetic.
 *
 *   A (8×8):
 *     row 0:  (0,2)  (3,7)
 *     row 1:  (1,5)  (4,3)  (6,1)
 *     row 2:  (0,4)  (2,8)
 *     row 3:  (3,6)  (5,2)  (7,9)
 *     row 4:  (1,1)  (4,5)
 *     row 5:  (0,3)  (3,4)  (5,7)
 *     row 6:  (2,2)  (6,6)  (7,3)
 *     row 7:  (1,8)  (4,2)  (7,4)
 *
 *   x = [1, 2, 3, 4, 5, 6, 7, 8]^T
 *
 *   Expected y = A·x:
 *     y[0] = 2·1 + 7·4               = 30
 *     y[1] = 5·2 + 3·5 + 1·7         = 32
 *     y[2] = 4·1 + 8·3               = 28
 *     y[3] = 6·4 + 2·6 + 9·8         = 108
 *     y[4] = 1·2 + 5·5               = 27
 *     y[5] = 3·1 + 4·4 + 7·6         = 61
 *     y[6] = 2·3 + 6·7 + 3·8         = 72
 *     y[7] = 8·2 + 2·5 + 4·8         = 58
 *     checksum = sum(y)               = 416  (0x1A0)
 */

#include "../runtime/fluxcore.h"

#define N    8
#define NNZ  21

/* Initialize CSR arrays via direct assignment.
 * Compiler emits ADDI+SW sequences — values are immediates in .text.
 * No .rodata section, no memcpy call.  All data lands in DMEM via SW. */
static void init_matrix(int *val, int *col_idx, int *row_ptr) {
    /* row 0 */
    val[0]=2;  col_idx[0]=0;
    val[1]=7;  col_idx[1]=3;
    /* row 1 */
    val[2]=5;  col_idx[2]=1;
    val[3]=3;  col_idx[3]=4;
    val[4]=1;  col_idx[4]=6;
    /* row 2 */
    val[5]=4;  col_idx[5]=0;
    val[6]=8;  col_idx[6]=2;
    /* row 3 */
    val[7]=6;  col_idx[7]=3;
    val[8]=2;  col_idx[8]=5;
    val[9]=9;  col_idx[9]=7;
    /* row 4 */
    val[10]=1; col_idx[10]=1;
    val[11]=5; col_idx[11]=4;
    /* row 5 */
    val[12]=3; col_idx[12]=0;
    val[13]=4; col_idx[13]=3;
    val[14]=7; col_idx[14]=5;
    /* row 6 */
    val[15]=2; col_idx[15]=2;
    val[16]=6; col_idx[16]=6;
    val[17]=3; col_idx[17]=7;
    /* row 7 */
    val[18]=8; col_idx[18]=1;
    val[19]=2; col_idx[19]=4;
    val[20]=4; col_idx[20]=7;

    row_ptr[0]=0;  row_ptr[1]=2;  row_ptr[2]=5;  row_ptr[3]=7;
    row_ptr[4]=10; row_ptr[5]=12; row_ptr[6]=15; row_ptr[7]=18;
    row_ptr[8]=21;
}

/* CSR SpMV kernel — hot inner loop, the primary measurement target */
static void spmv_csr(const int *val,
                     const int *col_idx,
                     const int *row_ptr,
                     const int *x,
                     int       *y,
                     int        nrows) {
    for (int i = 0; i < nrows; i++) {
        int acc = 0;
        for (int j = row_ptr[i]; j < row_ptr[i + 1]; j++) {
            acc += val[j] * x[col_idx[j]];
        }
        y[i] = acc;
    }
}

int main(void) {
    int val[NNZ], col_idx[NNZ], row_ptr[N + 1];
    int x[N], y[N];

    /* Input vector x = [1..8] */
    for (int i = 0; i < N; i++) x[i] = i + 1;

    init_matrix(val, col_idx, row_ptr);

    /* Warm-up run (fills pipeline, not measured) */
    for (int i = 0; i < N; i++) y[i] = 0;
    spmv_csr(val, col_idx, row_ptr, x, y, N);

    /* Timed run */
    for (int i = 0; i < N; i++) y[i] = 0;

    uint32_t t0 = fluxcore_cycle_start();
    uint32_t i0 = fluxcore_rdinstret();

    spmv_csr(val, col_idx, row_ptr, x, y, N);

    uint32_t cycles   = fluxcore_cycle_end(t0);
    uint32_t instrets = fluxcore_rdinstret() - i0;

    /* Correctness: checksum = sum(y) should be 416 = 0x1A0 */
    int checksum = 0;
    for (int i = 0; i < N; i++) checksum += y[i];

    fluxcore_report(cycles, instrets, (uint32_t)checksum,
                    (uint32_t)y[0], (uint32_t)y[3], (uint32_t)y[7]);

    return 0;
}
