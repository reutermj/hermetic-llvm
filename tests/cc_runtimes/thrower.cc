#include "tests/cc_runtimes/thrower.h"

#include <stdexcept>

void throw_runtime_error() { throw std::runtime_error("thrown"); }
