#ifndef ECHO_TEST_C_ABI_MEMORY_H
#define ECHO_TEST_C_ABI_MEMORY_H
#include <stddef.h>
// Returns the source line of a failed condition, or zero. Always releases handles
// and all C-owned returned strings before reporting a failure to XCTest.
int echo_test_c_ownership(const char *prompt, char *failure, size_t capacity);
#endif
