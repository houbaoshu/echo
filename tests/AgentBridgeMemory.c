#include "echo_agent.h"
#include "support/CABIMemory.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int echo_test_c_ownership(const char *prompt, char *failure, size_t capacity) {
    char request[8192];
    int failed = 0;
    for (int i = 0; i < 500 && !failed; ++i) {
        EchoAgent *handle = NULL;
        char *error = NULL, *batch = NULL, *invalid = NULL;
#define REQUIRE(condition) do { if (!(condition)) { \
    failed = __LINE__; snprintf(failure, capacity, "%s (iteration %d)", #condition, i); \
    goto cleanup; \
} } while (0)
        int size = snprintf(request, sizeof(request),
        "{\"version\":2,\"session_id\":\"memory\",\"generation\":\"memory-%d\",\"prompt_path\":\"%s\","
        "\"model\":{\"base_url\":\"http://127.0.0.1:1\",\"model\":\"test\",\"protocol\":\"responses\"},"
        "\"restore\":{\"source\":{\"type\":\"empty\"},\"input_receipts\":[],\"pending_inputs\":[],\"directory\":null}}", i, prompt);
        REQUIRE(size > 0 && (size_t)size < sizeof(request));
        handle = echo_agent_create(request, &error);
        REQUIRE(handle && !error);
        batch = echo_agent_poll_events(handle, 1);
        invalid = echo_agent_submit(handle, "{}");
        REQUIRE(invalid && strstr(invalid, "rejected"));
        echo_agent_cancel(handle);
        echo_agent_destroy(handle);
        handle = NULL;
        // Read returned allocations after handle destruction: C owns the copies.
        REQUIRE(batch && strstr(batch, "version"));
cleanup:
        if (handle) { echo_agent_cancel(handle); echo_agent_destroy(handle); }
        echo_agent_string_free(batch);
        echo_agent_string_free(invalid);
        echo_agent_string_free(error);
#undef REQUIRE
    }
    for (int i = 0; echo_agent_active_sessions() && i < 1000; ++i) usleep(10000);
    if (echo_agent_active_sessions() != 0 && !failed) {
        failed = __LINE__;
        snprintf(failure, capacity, "Rust session cleanup exceeded ten seconds");
    }
    return failed;
}
