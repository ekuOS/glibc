#include "check.hpp"

#include <array>
#include <cerrno>
#include <string_view>

#include <asm/prctl.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <x86intrin.h>

namespace {

using test::check;
using LegacyValue = auto (*)() noexcept -> int;

#ifdef ARCH_SHSTK_STATUS
constexpr int shadow_stack_status = ARCH_SHSTK_STATUS;
#else
constexpr int shadow_stack_status = 0x5005;
#endif
constexpr int unsupported_exit_code = 77;

auto check_legacy_symbol(void* handle) noexcept -> void {
    const auto legacy_value = reinterpret_cast<LegacyValue>(dlsym(handle, "legacy_value"));
    check(legacy_value != nullptr && legacy_value() == 42, "legacy_value lookup or call failed");
}

auto check_single_threaded_load(const char* library) noexcept -> void {
    void* const handle = dlopen(library, RTLD_NOW);
    if (handle == nullptr) {
        std::fprintf(stderr, "dlopen: %s\n", dlerror());
        std::exit(EXIT_FAILURE);
    }
    check(_get_ssp() == 0, "loading a legacy library must disable SHSTK");
    check_legacy_symbol(handle);
    check(dlclose(handle) == 0, "dlclose failed");
}

auto stay_alive(void* argument) noexcept -> void* {
    char byte{};
    const int fd = *static_cast<const int*>(argument);
    check(read(fd, &byte, 1) == 1, "worker could not read from pipe");
    return nullptr;
}

auto check_multithreaded_load(const char* library) noexcept -> void {
    std::array<int, 2> pipe_fds{};
    pthread_t thread{};
    check(pipe(pipe_fds.data()) == 0, "pipe failed");
    check(pthread_create(&thread, nullptr, stay_alive, &pipe_fds[0]) == 0, "pthread_create failed");
    check(dlopen(library, RTLD_NOW) == nullptr, "dlopen accepted a legacy library with multiple threads");
    const char* const error = dlerror();
    check(error != nullptr && std::string_view{error}.find("SHSTK support") != std::string_view::npos,
          "dlopen did not report missing SHSTK support");
    check(_get_ssp() != 0, "the rejected load disabled SHSTK");
    check(write(pipe_fds[1], "x", 1) == 1, "could not notify worker");
    check(pthread_join(thread, nullptr) == 0, "pthread_join failed");
    check(close(pipe_fds[0]) == 0 && close(pipe_fds[1]) == 0, "closing the pipe failed");
}

}  // namespace

auto main(int argc, char** argv) -> int {
    check(argc == 3, "expected a test mode and a legacy library path");
    const std::string_view mode{argv[1]};
    if (mode == "startup") {
        check(_get_ssp() == 0, "a legacy startup dependency must leave SHSTK disabled");
        check_legacy_symbol(RTLD_DEFAULT);
        return 0;
    }

    unsigned long status{};
    if (syscall(SYS_arch_prctl, shadow_stack_status, &status) != 0) {
        if (errno == EINVAL || errno == ENOSYS || errno == EOPNOTSUPP) {
            return unsupported_exit_code;
        }
        std::perror("ARCH_SHSTK_STATUS");
        return EXIT_FAILURE;
    }
    check(_get_ssp() != 0, "SHSTK was not active at startup");

    if (mode == "single") {
        check_single_threaded_load(argv[2]);
    } else {
        check(mode == "threaded", "unknown test mode");
        check_multithreaded_load(argv[2]);
    }
    return 0;
}
