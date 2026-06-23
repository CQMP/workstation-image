/*
 * vec_add.cu — long-running SAXPY demo for HTCondor CRIU checkpointing.
 *
 * Allocates two 256 MB float arrays on the GPU and runs ROUNDS iterations of
 * SAXPY, pausing 0.5 s between rounds.  Total wall time ~10 min.
 * Submit with want_checkpointing = true; after a checkpoint/restore the round
 * counter in the output continues from where it was frozen, confirming that
 * the process was restored rather than restarted.
 *
 * Compile:  nvcc -O2 -arch=sm_89 -o vec_add vec_add.cu
 */

#include <cuda_runtime.h>
#include <stdio.h>
#include <time.h>

#define N      (1 << 26)   /* 64 M floats = 256 MB per array */
#define ROUNDS 1200        /* 1200 x 0.5 s ~ 10 minutes      */

__global__ void saxpy(int n, float a, const float *x, float *y)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n)
        y[i] = a * x[i] + y[i];
}

static void timestamp(char *buf, size_t len)
{
    time_t t = time(NULL);
    struct tm *tm_info = localtime(&t);
    strftime(buf, len, "%Y-%m-%d %H:%M:%S", tm_info);
}

int main(void)
{
    float *d_x, *d_y;
    size_t bytes = (size_t)N * sizeof(float);

    cudaError_t err = cudaMalloc(&d_x, bytes);
    if (err != cudaSuccess) {
        fprintf(stderr, "cudaMalloc d_x: %s\n", cudaGetErrorString(err));
        return 1;
    }
    err = cudaMalloc(&d_y, bytes);
    if (err != cudaSuccess) {
        fprintf(stderr, "cudaMalloc d_y: %s\n", cudaGetErrorString(err));
        return 1;
    }
    cudaMemset(d_x, 0, bytes);
    cudaMemset(d_y, 0, bytes);

    char ts[32];
    timestamp(ts, sizeof(ts));
    printf("[%s] started -- %zu MB on device\n", ts, 2 * bytes >> 20);
    fflush(stdout);

    int threads = 256;
    int blocks  = (N + threads - 1) / threads;

    for (int r = 0; r < ROUNDS; r++) {
        saxpy<<<blocks, threads>>>(N, 1.0001f, d_x, d_y);
        err = cudaDeviceSynchronize();
        if (err != cudaSuccess) {
            fprintf(stderr, "saxpy round %d: %s\n", r, cudaGetErrorString(err));
            return 1;
        }

        timestamp(ts, sizeof(ts));
        printf("[%s] round %4d / %d\n", ts, r + 1, ROUNDS);
        fflush(stdout);

        struct timespec req = {0, 500000000L};  /* 0.5 s */
        nanosleep(&req, NULL);
    }

    cudaFree(d_x);
    cudaFree(d_y);

    timestamp(ts, sizeof(ts));
    printf("[%s] done.\n", ts);
    return 0;
}
