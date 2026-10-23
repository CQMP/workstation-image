# CUDA tools (nvcc, cuda-gdb, ...) on the PATH. The libraries are registered via /etc/ld.so.conf.d.
if [ -d /usr/local/cuda/bin ]; then
    case ":${PATH}:" in
        *:/usr/local/cuda/bin:*) ;;
        *) PATH="${PATH}:/usr/local/cuda/bin" ;;
    esac
    export PATH
fi
