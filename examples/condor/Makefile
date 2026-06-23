NVCC   = nvcc
# RTX 2000 Ada Generation (AD106) = compute capability 8.9
NVCCFLAGS = -O2 -arch=sm_89

.PHONY: all clean

all: vec_add

vec_add: vec_add.cu
	$(NVCC) $(NVCCFLAGS) -o $@ $<

clean:
	rm -f vec_add
