/*------------------------------------------------------------------------------------------------*
 * Copyright (C) by the DBCSR developers group - All rights reserved                              *
 * This file is part of the DBCSR library.                                                        *
 *                                                                                                *
 * For information on the license, see the LICENSE file.                                          *
 * For further information please visit https://dbcsr.cp2k.org                                    *
 * SPDX-License-Identifier: GPL-2.0+                                                              *
 *------------------------------------------------------------------------------------------------*/

/* number of M-blocks */
#define NBM ((SM + BM - 1) / BM)
/* number of N-blocks */
#define NBN ((SN + BN - 1) / BN)
/* size of workgroup (WG) */
#define SWG (NBM * NBN)


#if !defined(cl_intel_global_float_atomics)

__attribute__((always_inline))
inline void atomic_add_global_cmpxchg(global volatile T* dst, T inc)
{
  union { T f; TA a; } old_val, try_val, new_val = { .f = *dst };
  do {
    old_val.a = new_val.a;
    try_val.f = old_val.f + inc;
    new_val.a = CMPXCHG((global volatile TA*)dst, old_val.a, try_val.a);
  } while (old_val.a != new_val.a);
}

__attribute__((always_inline))
inline void atomic_add_global_cmpxchg2(global volatile float2* dst, float2 inc)
{
  union { float2 f; long a; } old_val, try_val, new_val = { .f = *dst };
  do {
    old_val.a = new_val.a;
    try_val.f = old_val.f + inc;
    new_val.a = atom_cmpxchg((global volatile long*)dst, old_val.a, try_val.a);
  } while (old_val.a != new_val.a);
}

__attribute__((always_inline))
inline void atomic_add_global_xchg(global volatile T* dst, T inc)
{
  union { T f; TA a; } old_val = { .f = inc }, try_val, new_val = { .f = 0 };
  do {
    try_val.a = XCHG((global volatile TA*)dst, new_val.a);
    try_val.f += old_val.f;
    old_val.a = XCHG((global volatile TA*)dst, try_val.a);
  } while (old_val.a != new_val.a);
}

#endif


kernel void FN(global T *restrict cmat,
  GLOBAL const T *restrict amat, GLOBAL const T *restrict bmat,
#if (1 < BS)
  GLOBAL const int *restrict param_stack, int stack_size)
#else
  GLOBAL const int *restrict param_stack)
#endif
{
  const int gid = get_group_id(0), idx = get_local_id(0);
  GLOBAL const int *const restrict params = param_stack + gid * (3 * BS);
  /* indexes given by param_stack are one-based */
  int a0 = params[0] - 1, b0 = params[1] - 1, c0 = params[2] - 1;
  global T *restrict cwg = cmat + c0;

  local T a[SM][SK];
  T am[SK], bn[SK];
#if (SWG != SN)
  local T b[SK][SN];
# if (1 < BS)
  T c[BM][BN] = {{ 0 }};
# endif
#else
# if (1 < BS)
  T c[SM] = { 0 };
# endif
#endif

  /* intra-kernel mini-batch of SMMs */
#if (1 < BS)
  const int batchsize = min(BS, stack_size - BS * gid);
  for (int i = 0; i < batchsize; ++i)
#endif
  {
#if (SWG != SN)
    const int im = idx / NBN;
    const int m0 = im * BM, m1 = min(m0 + BM, SM);
    const int n0 = (idx - im * NBN) * BN;
    const int n1 = min(n0 + BN, SN);
#else
    const int bm = (SM + SWG - 1) / SWG;
    const int m0 = idx * bm, m1 = min(m0 + bm, SM);
    const int n = idx;
#endif

#if (1 < BS)
    int a1, b1, c1;
    if (i < (batchsize - 1)) {
      a1 = params[3*i+3] - 1;
      b1 = params[3*i+4] - 1;
      c1 = params[3*i+5] - 1;
    }
    else {
      a1 = b1 = c1 = -1;
    }
#endif

    { /* transpose A-matrix into local buffer */
      GLOBAL const T *const restrict awg = amat + a0;
      for (int m = m0; m < m1; ++m) {
        for (int k = 0; k < SK; ++k) a[m][k] = awg[SM*k+m];
      }
#if (1 < BS)
      a0 = a1; /* next iteration */
#endif
    }

    { /* copy B-matrix into local or private buffer */
      GLOBAL const T *const restrict bwg = bmat + b0;
      for (int k = 0; k < SK; ++k) {
#if (SWG != SN)
        for (int n = n0; n < n1; ++n) b[k][n] = bwg[SN*k+n];
#else
        bn[k] = bwg[SN*k+n];
#endif
      }
#if (1 < BS)
      b0 = b1; /* next iteration */
#endif
    }

    { /* calculate private result-tile */
      barrier(CLK_LOCAL_MEM_FENCE);
#if (SWG != SN)
      for (int m = m0; m < m1; ++m) {
        for (int k = 0; k < SK; ++k) am[k] = a[m][k];
        for (int n = n0; n < n1; ++n) {
          T r = 0;
          for (int k = 0; k < SK; ++k) bn[k] = b[k][n];
          for (int k = 0; k < SK; ++k) r = FMA(am[k], bn[k], r);
# if (1 < BS)
          c[m-m0][n-n0] += r;
# else
          ATOMIC_ADD_GLOBAL(&cwg[SM*n+m], r);
# endif
        }
      }
#else
      for (int m = 0; m < SM; ++m) {
        T r = 0;
        for (int k = 0; k < SK; ++k) am[k] = a[m][k];
        for (int k = 0; k < SK; ++k) r = FMA(am[k], bn[k], r);
# if (1 < BS)
        c[m] += r;
# else
        ATOMIC_ADD_GLOBAL(&cwg[SM*n+m], r);
# endif
      }
#endif
    }

#if (1 < BS)
    if (c0 != c1) { /* copy private tile to global memory */
# if (SWG != SN)
      for (int m = 0; m < BM; ++m) for (int n = 0; n < BN; ++n) {
        const int gm = m + m0, gn = n + n0;
        if (gm < SM && gn < SN) {
          ATOMIC_ADD_GLOBAL(&cwg[SM*gn+gm], c[m][n]);
          c[m][n] = 0; /* reset */
        }
      }
# else
#   if defined(ATOMIC_ADD2_GLOBAL)
      for (int m = 0; m < SM; m += 2) {
        ATOMIC_ADD2_GLOBAL((global volatile float2*)(cwg + SM * n + m), *(const float2*)(c + m));
        c[m] = c[m+1] = 0; /* reset */
      }
#   else
      for (int m = 0; m < SM; ++m) {
        ATOMIC_ADD_GLOBAL(&cwg[SM*n+m], c[m]);
        c[m] = 0; /* reset */
      }
#   endif
# endif
      /* next iteration */
      cwg = cmat + c1;
      c0 = c1;
    }
    barrier(CLK_LOCAL_MEM_FENCE);
#endif
  }
}
