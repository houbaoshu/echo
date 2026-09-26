#ifndef ECHO_PROBE_EXEC_H
#define ECHO_PROBE_EXEC_H
/* Probe-only C ABI over mini-agent-rs LocalConversationExecutor (see EchoExecutorFFI/src/lib.rs).
 * start never blocks; wait blocks until the executor returns (including process-tree cleanup);
 * cancel may be called any time before free; wait returns {"outcome":"completed","output":"<CommandOutput JSON>"} |
 * {"outcome":"cancelled"} | {"outcome":"error",...}. Free returned strings with probe_exec_string_free. */
typedef struct ProbeExec ProbeExec;
ProbeExec *probe_exec_start(const char *command, const char *directory);
void probe_exec_cancel(ProbeExec *exec);
char *probe_exec_wait(ProbeExec *exec);
void probe_exec_free(ProbeExec *exec);
void probe_exec_string_free(char *value);
#endif
