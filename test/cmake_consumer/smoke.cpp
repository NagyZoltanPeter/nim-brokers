// C++ smoke test for the generated mylib CMake package.
//
// In native mode, mylib::Mylib is the wrapper class. CBOR-mode wrappers
// expose a similar Lib class but with different request semantics — this
// smoke test only exercises the lifecycle (createContext / shutdown), so
// it compiles and links against either build mode.

#include "mylib.hpp"

#include <cstdio>
#include <string_view>

int main() {
    constexpr std::string_view kExpectedVersion{"1.0.0"};
    if (mylib::Mylib::version() != kExpectedVersion) {
        std::fprintf(stderr,
                     "Mylib::version mismatch: got '%.*s', expected '%.*s'\n",
                     static_cast<int>(mylib::Mylib::version().size()),
                     mylib::Mylib::version().data(),
                     static_cast<int>(kExpectedVersion.size()),
                     kExpectedVersion.data());
        return 10;
    }

    mylib::Mylib lib;
    auto r = lib.createContext();
    if (!r.isOk()) {
        std::fprintf(stderr, "createContext failed: %s\n", r.error().c_str());
        return 1;
    }
    if (!lib.validContext()) {
        std::fprintf(stderr, "validContext returned false after createContext\n");
        return 2;
    }
    std::printf("smoke_cpp: OK (ctx=%u)\n", lib.ctx());
    // shutdown is invoked from Mylib's destructor.
    return 0;
}
