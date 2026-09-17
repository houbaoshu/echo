#ifndef ECHO_AGENT_H
#define ECHO_AGENT_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct EchoAgent EchoAgent;
/* JSON wire version is 2 only; persistent history schema remains version 1.
 * create: {version, session_id, generation, prompt_path, model, restore}.
 * Every handle needs a new nonempty generation. restore.directory is required
 * (null clears it); restore.source.v1 history is an opaque JSON string.
 * requests: {version:2, request_id, command:{type,...}}. submit/steer/directory
 * entrypoints validate the nested command type. Normal sends use request with
 * send_message and a stable client_message_id. Queued admission is not applied.
 * acknowledge_checkpoint / checkpoint_failed / authorize_tool sent via request
 * bypass the ordinary command queue. Save checkpoints before acknowledging;
 * authorize a tool only while holding its matching directory lease.
 * poll: {version:2,batches:[...],closed:bool,stream?}. stream is the running model
 * operation's latest display-only text {turn_id,operation_id,text,tool_call},
 * present when it changed since the previous poll; it is never checkpointed.
 * A Cancelled batch confirms Stop
 * cleanup; active_sessions confirms close/destroy cleanup for process shutdown.
 * See docs/mini-agent-mainline-bridge-v2-contract.md for full JSON types.
 * All JSON strings use UTF-8. Inputs are borrowed only during the call.
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
