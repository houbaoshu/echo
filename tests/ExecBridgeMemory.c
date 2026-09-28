#include "echo_exec.h"
#include "support/CABIMemory.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <unistd.h>

// One completion slot per handle: the callback copies the borrowed result into C-owned memory.
typedef struct {
    pthread_mutex_t lock;
    char *result;
    atomic_int calls;
} Slot;

static void done(void *context, const char *result) {
    Slot *slot = context;
    pthread_mutex_lock(&slot->lock);
    slot->result = strdup(result);
    pthread_mutex_unlock(&slot->lock);
    atomic_fetch_add(&slot->calls, 1);
}

int echo_test_exec_ownership(const char *path, char *failure, size_t capacity) {
    enum { COUNT = 200 };
    char directory[PATH_MAX];
    if (!realpath(path, directory)) { snprintf(failure, capacity, "realpath failed"); return __LINE__; }
    Slot slots[COUNT];
    char request[4096];
    int failed = 0, started = 0;
#define REQUIRE(condition) do { if (!(condition)) { \
    failed = __LINE__; snprintf(failure, capacity, "%s (iteration %d)", #condition, i); \
    goto cleanup; \
} } while (0)
    for (int i = 0; i < COUNT; ++i) {
        pthread_mutex_init(&slots[i].lock, NULL);
        slots[i].result = NULL;
        atomic_init(&slots[i].calls, 0);
    }
    for (int i = 0; i < COUNT; ++i) {
        char *error = NULL;
        // Rejected requests allocate only the error, which C frees.
        EchoExec *rejected = echo_exec_start("{\"version\":1}", &slots[i], done, &error);
        REQUIRE(!rejected && error && strstr(error, "invalid"));
        echo_exec_string_free(error);
        error = NULL;
        int size = snprintf(request, sizeof(request),
            "{\"version\":1,\"command\":\"%s\",\"directory\":\"%s\"}", i % 3 ? "printf ok-%d" : "sleep 5", directory);
        REQUIRE(size > 0 && (size_t)size < sizeof(request));
        char command[4096];
        snprintf(command, sizeof(command), request, i);
        EchoExec *handle = echo_exec_start(command, &slots[i], done, &error);
        REQUIRE(handle && !error);
        ++started;
        // Cancel some while running, release every handle before its result arrives.
        if (i % 3 == 0) echo_exec_cancel(handle);
        echo_exec_release(handle);
    }
cleanup:
    for (int i = 0; echo_exec_active() && i < 1500; ++i) usleep(10000);
    if (!failed && echo_exec_active() != 0) {
        failed = __LINE__;
        snprintf(failure, capacity, "commands still active after fifteen seconds");
    }
    for (int i = 0; i < started && !failed; ++i) {
        // Read results after every handle was released: C owns the copies.
        if (atomic_load(&slots[i].calls) != 1 || !slots[i].result
            || !strstr(slots[i].result, i % 3 ? "\"completed\"" : "\"cancelled\"")) {
            failed = __LINE__;
            snprintf(failure, capacity, "result %d: calls=%d %s", i, atomic_load(&slots[i].calls),
                     slots[i].result ? slots[i].result : "(none)");
        }
    }
    for (int i = 0; i < COUNT; ++i) {
        free(slots[i].result);
        pthread_mutex_destroy(&slots[i].lock);
    }
#undef REQUIRE
    return failed;
}
