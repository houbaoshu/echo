#ifndef ECHO_AGENT_H
#define ECHO_AGENT_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct EchoAgent EchoAgent;
/* All JSON strings use UTF-8. Inputs are borrowed only during the call.
 * Every returned char* (including errors) must be freed with string_free.
 * Calls never wait for network, commands, event capacity or worker shutdown.
 * Serialize calls for a handle; never use it after destroy. */
EchoAgent *echo_agent_create(const char *request, char **error);
char *echo_agent_submit(EchoAgent *, const char *request);
char *echo_agent_steer(EchoAgent *, const char *request);
char *echo_agent_provide_directory(EchoAgent *, const char *request);
char *echo_agent_request(EchoAgent *, const char *request);
void echo_agent_cancel(EchoAgent *);
char *echo_agent_poll_events(EchoAgent *, size_t max_batches);
void echo_agent_destroy(EchoAgent *);
size_t echo_agent_active_sessions(void);
void echo_agent_string_free(char *value);
#ifdef __cplusplus
}
#endif
#endif
