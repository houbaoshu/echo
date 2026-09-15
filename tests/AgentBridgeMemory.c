#include "echo_agent.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    assert(argc == 2);
    char request[8192];
    for (int i = 0; i < 500; ++i) {
        int size = snprintf(request, sizeof(request),
        "{\"version\":2,\"session_id\":\"memory\",\"generation\":\"memory-%d\",\"prompt_path\":\"%s\","
        "\"model\":{\"base_url\":\"http://127.0.0.1:1\",\"model\":\"test\",\"protocol\":\"responses\"},"
        "\"restore\":{\"source\":{\"type\":\"empty\"},\"input_receipts\":[],\"pending_inputs\":[],\"directory\":null}}", i, argv[1]);
        assert(size > 0 && (size_t)size < sizeof(request));
        char *error = NULL;
        EchoAgent *handle = echo_agent_create(request, &error);
        assert(handle && !error);
        char *batch = echo_agent_poll_events(handle, 1);
        char *invalid = echo_agent_submit(handle, "{}");
        assert(strstr(invalid, "rejected"));
        echo_agent_cancel(handle);
        echo_agent_destroy(handle);
        assert(strstr(batch, "version"));
        echo_agent_string_free(batch);
        echo_agent_string_free(invalid);
        echo_agent_string_free(error);
    }
    for (int i = 0; echo_agent_active_sessions() && i < 1000; ++i) usleep(10000);
    assert(echo_agent_active_sessions() == 0);
    puts("C ABI allocation/free stress passed (500 handles).");
}
