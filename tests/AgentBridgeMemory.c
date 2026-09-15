#include "echo_agent.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    assert(argc == 2);
    char request[8192];
    snprintf(request, sizeof(request),
        "{\"version\":1,\"session_id\":\"memory\",\"prompt_path\":\"%s\","
        "\"model\":{\"base_url\":\"http://127.0.0.1:1\",\"model\":\"test\",\"protocol\":\"responses\"}}", argv[1]);
    for (int i = 0; i < 500; ++i) {
        char *error = NULL;
        EchoAgent *handle = echo_agent_create(request, &error);
        assert(handle && !error);
        char *batch = echo_agent_poll_events(handle, 1);
        char *invalid = echo_agent_submit(handle, "{}");
        assert(strstr(invalid, "false"));
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
