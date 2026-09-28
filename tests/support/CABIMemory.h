#ifndef ECHO_TEST_C_ABI_MEMORY_H
#define ECHO_TEST_C_ABI_MEMORY_H
#include <stddef.h>
// The execution ABI: 200 handles, released before their results, some cancelled; every
// callback runs exactly once and every result is copied into C-owned memory. Returns the
// source line of a failed condition, or zero, after releasing everything it allocated.
int echo_test_exec_ownership(const char *directory, char *failure, size_t capacity);
#endif
