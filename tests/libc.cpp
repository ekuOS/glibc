#include "check.hpp"

#include <array>
#include <clocale>
#include <cwchar>
#include <string_view>

#include <dlfcn.h>
#include <gnu/libc-version.h>
#include <netdb.h>
#include <sys/stat.h>

namespace {

using test::check;

auto check_loaded_libc(const char* expected_path) noexcept -> void {
    Dl_info info{};
    check(dladdr(reinterpret_cast<const void*>(&gnu_get_libc_version), &info) != 0 &&
          info.dli_fname != nullptr, "could not identify the loaded libc");

    struct stat expected{};
    struct stat loaded{};
    check(stat(expected_path, &expected) == 0, "could not stat the expected libc");
    check(stat(info.dli_fname, &loaded) == 0, "could not stat the loaded libc");
    if (loaded.st_dev != expected.st_dev || loaded.st_ino != expected.st_ino) {
        std::fprintf(stderr, "Loaded libc %s instead of %s\n", info.dli_fname, expected_path);
        std::exit(EXIT_FAILURE);
    }
}

auto check_stdio() noexcept -> void {
    constexpr std::string_view expected{"glibc runtime 42\n"};
    std::FILE* const file = std::tmpfile();
    check(file != nullptr, "tmpfile failed");
    const int written = std::fprintf(file, "%s %d\n", "glibc runtime", 42);
    check(written == static_cast<int>(expected.size()), "formatted write failed");
    check(std::fflush(file) == 0, "fflush failed");
    check(std::fseek(file, 0, SEEK_SET) == 0, "fseek failed");

    std::array<char, expected.size()> buffer{};
    const std::size_t read = std::fread(buffer.data(), 1, buffer.size(), file);
    check(std::string_view{buffer.data(), read} == expected, "file contents do not match the formatted write");
    check(std::fgetc(file) == EOF && std::feof(file) != 0 && std::ferror(file) == 0,
          "reading past the end of the file did not report EOF");
    check(std::fclose(file) == 0, "fclose failed");
}

auto check_locale() noexcept -> void {
    check(std::setlocale(LC_ALL, "C") != nullptr, "could not select the C locale");
    const auto* conventions = std::localeconv();
    check(conventions != nullptr && std::string_view{conventions->decimal_point} == ".",
          "the C locale returned an unexpected decimal separator");

    std::mbstate_t state{};
    wchar_t character{};
    check(std::mbrtowc(&character, "A", 1, &state) == 1 && character == L'A',
          "multibyte conversion failed in the C locale");
}

auto check_address_resolution() noexcept -> void {
    addrinfo hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV;

    addrinfo* address = nullptr;
    check(getaddrinfo("127.0.0.1", "4242", &hints, &address) == 0 && address != nullptr,
          "getaddrinfo could not resolve a numeric loopback address");
    check(address->ai_family == AF_INET && address->ai_socktype == SOCK_STREAM,
          "getaddrinfo returned an unexpected address type");

    std::array<char, NI_MAXHOST> host{};
    std::array<char, NI_MAXSERV> service{};
    const int status = getnameinfo(address->ai_addr, address->ai_addrlen,
                                   host.data(), host.size(), service.data(), service.size(),
                                   NI_NUMERICHOST | NI_NUMERICSERV);
    freeaddrinfo(address);
    check(status == 0 && std::string_view{host.data()} == "127.0.0.1" &&
          std::string_view{service.data()} == "4242", "numeric address round trip failed");
}

}  // namespace

auto main(int argc, char** argv) -> int {
    check(argc == 1 || argc == 2, "expected at most one libc path");
    if (argc == 2) {
        check_loaded_libc(argv[1]);
    }

    check_stdio();
    check_locale();
    check_address_resolution();
    return 0;
}
