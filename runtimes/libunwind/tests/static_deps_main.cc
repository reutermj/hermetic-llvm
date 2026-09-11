#include <cstdio>
#include <stdexcept>

#include "runtimes/libunwind/tests/mid.h"

int main() {
  try {
    mid_function();
  } catch (const std::runtime_error& error) {
    std::printf("exception caught\n");
    return 0;
  }
  std::fprintf(stderr, "no exception caught\n");
  return 1;
}
