#ifndef ECHO_EXEC_H
#define ECHO_EXEC_H
#include <stdbool.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* One shell command per handle, run by mini-agent-exec's LocalExecutor
 * (/bin/zsh -f -c: no user startup files, inherited environment, stdin null,
 * per-stream output limit, timeout, and every descendant killed when the command ends).
 *
 * request: {"version":1,"command":string,"directory":canonical absolute path,
 *           "timeout_ms"?:integer (default 30000),"max_output_bytes"?:integer (default 65536)}
 * result:  {"version":1,"outcome":"completed","output":string}
 *        | {"version":1,"outcome":"cancelled"}
 *        | {"version":1,"outcome":"failed","error":{"code":string,"message":string}}
 *   output is mini-agent-rs's CommandOutput serialized as JSON, in its field order, the
 *   same text Mini Agent writes into history. "invalid_directory"
 *   means the directory no longer resolves to itself.
 *
 * start never blocks. It creates the runtime on first use; nothing else does.
 * done is called exactly once per started handle, on a runtime thread, after the
 * command and all its descendants are gone; result is borrowed for the call.
 * context must stay valid until then. cancel is idempotent and never blocks; a
 * command that already finished still reports "completed". release may be called
 * at any time and does not cancel. active counts started handles whose done has
 * not returned yet. Inputs are borrowed only during the call; *error must be
 * freed with echo_exec_string_free. */
typedef struct EchoExec EchoExec;
typedef void (*echo_exec_done)(void *context, const char *result);
EchoExec *echo_exec_start(const char *request, void *context, echo_exec_done done, char **error);
void echo_exec_cancel(EchoExec *exec);
void echo_exec_release(EchoExec *exec);
size_t echo_exec_active(void);
/* Whether any command ever started the runtime; for tests that assert it never did. */
bool echo_exec_runtime_started(void);
void echo_exec_string_free(char *value);
#ifdef __cplusplus
}
#endif
#endif
