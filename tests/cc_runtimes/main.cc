#include <cstdio>
#include <stdexcept>

#include "tests/cc_runtimes/thrower.h"

int main() {
  try {
    throw_runtime_error();
  } catch (const std::runtime_error& error) {
    std::printf("exception caught: %s\n", error.what());
    return 0;
  }
  std::printf("no exception\n");
  return 1;
}
