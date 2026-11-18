#include "check.hpp"

#include <algorithm>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

#include <malloc.h>
#include <pthread.h>
#include <sys/wait.h>
#include <unistd.h>

// The host headers may predate these glibc interfaces.
extern "C" auto free_sized(void* pointer, std::size_t size) noexcept -> void;
extern "C" auto free_aligned_sized(void* pointer, std::size_t alignment, std::size_t size) noexcept -> void;

namespace {

using test::check;

auto is_aligned(const void* pointer, std::size_t alignment) noexcept -> bool {
    return pointer != nullptr && reinterpret_cast<std::uintptr_t>(pointer) % alignment == 0;
}

auto check_allocations() noexcept -> void {
    constexpr std::size_t count = 32;
    constexpr std::size_t element_size = 4;
    constexpr std::size_t allocation_size = count * element_size;
    constexpr std::size_t allocation_alignment = 4096;
    constexpr unsigned char fill = 0x5a;

    errno = EDOM;
    void* const small = std::malloc(1);
    check(is_aligned(small, alignof(std::max_align_t)), "malloc(1) returned an invalid or misaligned pointer");
    check(errno == EDOM, "successful malloc changed errno");
    check(malloc_usable_size(small) >= 1, "malloc_usable_size returned less than the requested size");
    free_sized(small, 1);
    check(errno == EDOM, "free_sized changed errno");

    auto* buffer = static_cast<unsigned char*>(std::calloc(count, element_size));
    check(buffer != nullptr, "calloc failed");
    check(std::all_of(buffer, buffer + allocation_size, [](unsigned char byte) noexcept -> bool {
        return byte == 0;
    }),
          "calloc returned nonzero bytes");
    std::memset(buffer, fill, allocation_size);
    buffer = static_cast<unsigned char*>(std::realloc(buffer, 4096));
    check(buffer != nullptr, "realloc failed to grow the allocation");
    check(std::all_of(buffer, buffer + allocation_size, [](unsigned char byte) noexcept -> bool {
        return byte == fill;
    }),
          "realloc changed the contents of the allocation");

    const volatile std::size_t huge = std::numeric_limits<std::size_t>::max();
    errno = 0;
    check(std::realloc(buffer, huge) == nullptr && errno == ENOMEM, "oversized realloc must fail with ENOMEM");
    check(buffer[0] == fill, "failed realloc changed the original allocation");
    check(std::realloc(buffer, 0) == nullptr, "realloc with size zero must free the allocation");
    errno = 0;
    check(std::calloc(huge, 2) == nullptr && errno == ENOMEM, "overflowing calloc must fail with ENOMEM");

    void* const aligned = std::aligned_alloc(allocation_alignment, allocation_alignment);
    check(is_aligned(aligned, allocation_alignment), "aligned_alloc did not honor the requested alignment");
    free_aligned_sized(aligned, allocation_alignment, allocation_alignment);

    void* result = nullptr;
    check(posix_memalign(&result, 3, 17) == EINVAL && result == nullptr,
          "posix_memalign must reject an invalid alignment and preserve the output pointer");
    check(posix_memalign(&result, 256, 17) == 0, "posix_memalign failed");
    check(is_aligned(result, 256), "posix_memalign returned a misaligned pointer");
    std::free(result);
}

auto check_allocator_diagnostics() noexcept -> void {
    errno = 0;
    check(malloc_info(0, stdout) == -1 && errno == ENOSYS, "malloc_info must report ENOSYS");
    errno = 0;
    check(malloc_info(1, stdout) == -1 && errno == EINVAL, "malloc_info must reject invalid options");
    check(mallopt(M_TRIM_THRESHOLD, 1024) == 0, "mallopt accepted a ptmalloc setting");
    const auto stats = mallinfo2();
    check(stats.arena == 0 && stats.uordblks == 0 && stats.hblkhd == 0,
          "mallinfo2 reported ptmalloc counters");
}

auto release_on_thread(void* allocation) noexcept -> void* {
    std::free(allocation);
    return nullptr;
}

auto allocate_in_child() noexcept -> void {
    void* const allocation = std::malloc(4096);
    if (allocation == nullptr) {
        _exit(1);
    }
    std::memset(allocation, 0x5a, 4096);
    std::free(allocation);
}

auto check_threads_and_fork() noexcept -> void {
    pthread_t worker{};
    void* const allocation = std::malloc(4096);
    check(allocation != nullptr, "malloc failed before cross-thread free");
    check(pthread_create(&worker, nullptr, release_on_thread, allocation) == 0, "pthread_create failed");
    check(pthread_join(worker, nullptr) == 0, "pthread_join failed");

    check(pthread_atfork(nullptr, nullptr, allocate_in_child) == 0, "pthread_atfork failed");
    const pid_t child = fork();
    check(child >= 0, "fork failed");
    if (child == 0) {
        _exit(0);
    }

    int status{};
    check(waitpid(child, &status, 0) == child, "waitpid failed");
    check(WIFEXITED(status) && WEXITSTATUS(status) == 0, "allocation in the fork child failed");
}

}  // namespace

auto main() -> int {
    check_allocations();
    check_allocator_diagnostics();
    check_threads_and_fork();
    return 0;
}
