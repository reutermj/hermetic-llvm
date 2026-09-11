#pragma once

// Calls throw_from_shared_library(); a middle layer so the binary has a direct
// dependency (mid) and a transitive one (thrower).
void mid_function();
