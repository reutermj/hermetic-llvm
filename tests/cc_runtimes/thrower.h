#pragma once

// Throws std::runtime_error; defined in a separate object so the throw and the
// catch can live in different modules.
void throw_runtime_error();
