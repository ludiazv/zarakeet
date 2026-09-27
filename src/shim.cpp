// extern "C" wrappers for parakeet.cpp functions that parakeet_capi.h does not expose.
#include "ggml_graph.hpp"

extern "C" void zarakeet_set_num_threads(int n) { pk::set_num_threads(n); }
extern "C" void zarakeet_shutdown_backend(void) { pk::shutdown_backend(); }