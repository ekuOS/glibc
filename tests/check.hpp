#pragma once

#include <cstdio>
#include <cstdlib>
#include <source_location>

namespace test {

inline auto check(bool passed, const char* message,
                  std::source_location location = std::source_location::current()) noexcept -> void {
    if (!passed) {
        std::fprintf(stderr, "%s:%u: %s\n", location.file_name(),
                     static_cast<unsigned>(location.line()), message);
        std::exit(EXIT_FAILURE);
    }
}

}  // namespace test
