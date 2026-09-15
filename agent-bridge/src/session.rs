use mini_agent::{
    conversation::{
        Conversation, ConversationConfig, ConversationHistory, ConversationMessage,
        ConversationModel, Operation,
    },
    models::{ApiProtocol, OpenAiConfig, OpenAiModel},
    types::CommandOutput,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    path::PathBuf,
    sync::{
        Arc, OnceLock,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::{
    runtime::Runtime,
    sync::{mpsc, watch},
    task::JoinHandle,
};

pub const COMMAND_CAPACITY: usize = 32;
pub const EVENT_CAPACITY: usize = 64;
pub static ACTIVE: AtomicUsize = AtomicUsize::new(0);
static RUNTIME: OnceLock<std::result::Result<Runtime, String>> = OnceLock::new();

pub fn runtime() -> Result<&'static Runtime, String> {
    RUNTIME
        .get_or_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .thread_name("echo-agent")
                .enable_all()
                .build()
                .map_err(|_| "cannot create agent runtime".into())
        })
        .as_ref()
        .map_err(Clone::clone)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Create {
    pub version: u32,
    pub session_id: String,
    pub prompt_path: PathBuf,
    pub model: ModelConfig,
    pub history: Option<ConversationHistory>,
    pub directory: Option<PathBuf>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelConfig {
    pub base_url: String,
    pub model: String,
    pub api_key: Option<String>,
    pub protocol: Protocol,
}
#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Protocol {
    ChatCompletions,
    Responses,
}

#[derive(Deserialize)]
pub struct Request {
    pub version: u32,
    pub request_id: String,
    #[serde(flatten)]
    pub command: Command,
    #[serde(skip)]
    pub cancel_generation: u64,
}
#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    Submit {
        text: String,
    },
    Steer {
        text: String,
    },
    ProvideDirectory {
        directory: Option<PathBuf>,
    },
    Continue,
    ExportHistory,
    /// Stage 3 uses this gate after durable intent and directory-lock acquisition.
    StartTool {
        operation_id: u64,
    },
}

pub struct Channels {
    pub commands: mpsc::Sender<Request>,
    pub events: std::sync::Mutex<mpsc::Receiver<Value>>,
    pub cancel: watch::Sender<u64>,
    pub destroy: watch::Sender<bool>,
}
struct Count;
impl Drop for Count {
    fn drop(&mut self) {
        ACTIVE.fetch_sub(1, Ordering::SeqCst);
    }
}

pub fn spawn(config: Create) -> Result<Arc<Channels>, String> {
    let runtime = runtime()?;
    let (commands, rx) = mpsc::channel(COMMAND_CAPACITY);
    let (tx, events) = mpsc::channel(EVENT_CAPACITY);
    let (cancel, cancel_rx) = watch::channel(0);
    let (destroy, destroy_rx) = watch::channel(false);
    ACTIVE.fetch_add(1, Ordering::SeqCst);
    runtime.spawn(async move {
        let _count = Count;
        let id = config.session_id.clone();
        // Filesystem and client initialization never run on the calling UI thread.
        let initialized = tokio::task::spawn_blocking(move || initialize(config));
        tokio::pin!(initialized);
        let mut destroy_rx = destroy_rx;
        let result = tokio::select! {
            biased;
            _ = destroy_rx.changed() => { let _ = initialized.await; return; },
            result = &mut initialized => result,
        };
        match result {
            Ok(Ok((core, model))) => {
                Worker::new(core, model, rx, tx, cancel_rx, destroy_rx)
                    .run()
                    .await
            }
            _ => {
                // Do not echo config/key/path/provider details in initialization errors.
                let frame = json!({"version":1,"session_id":id,"type":"initialization_failed"});
                tokio::select! { _ = tx.send(frame) => {}, _ = destroy_rx.changed() => {} }
            }
        }
    });
    Ok(Arc::new(Channels {
        commands,
        events: std::sync::Mutex::new(events),
        cancel,
        destroy,
    }))
}

fn initialize(
    config: Create,
) -> mini_agent::Result<(Conversation, Arc<tokio::sync::Mutex<OpenAiModel>>)> {
    let prompt = std::fs::read_to_string(config.prompt_path)?;
    let settings = ConversationConfig::new(prompt);
    let mut core = if let Some(history) = config.history {
        if history.session_id != config.session_id {
            return Err(mini_agent::Error::Config("history session mismatch".into()));
        }
        Conversation::from_history(settings, history)?
    } else {
        Conversation::new(config.session_id, settings)?
    };
    if config.directory.is_some() {
        // A project can disappear between Swift's availability check and this
        // background initialization. Chat remains usable; the first tool pauses.
        if core.provide_directory(config.directory).is_err() {
            core.provide_directory(None)?;
        }
    }
    let model = OpenAiModel::with_protocol(
        OpenAiConfig {
            base_url: config.model.base_url,
            model: config.model.model,
            api_key: config.model.api_key,
            timeout: Duration::from_secs(60),
        },
        match config.model.protocol {
            Protocol::ChatCompletions => ApiProtocol::ChatCompletions,
            Protocol::Responses => ApiProtocol::Responses,
        },
    )?;
    Ok((core, Arc::new(tokio::sync::Mutex::new(model))))
}

enum Completion {
    Model(mini_agent::Result<ConversationMessage>),
    Tool(mini_agent::Result<CommandOutput>),
}
struct Running {
    id: u64,
    task: JoinHandle<Completion>,
    stop: Option<watch::Sender<bool>>,
}
struct Worker {
    core: Conversation,
    model: Arc<tokio::sync::Mutex<OpenAiModel>>,
    commands: mpsc::Receiver<Request>,
    events: mpsc::Sender<Value>,
    cancel: watch::Receiver<u64>,
    destroy: watch::Receiver<bool>,
    pending: VecDeque<Value>,
    running: Option<Running>,
    proposal: Option<u64>,
    authorized: Option<u64>,
}

impl Worker {
    fn new(
        core: Conversation,
        model: Arc<tokio::sync::Mutex<OpenAiModel>>,
        commands: mpsc::Receiver<Request>,
        events: mpsc::Sender<Value>,
        cancel: watch::Receiver<u64>,
        destroy: watch::Receiver<bool>,
    ) -> Self {
        Self {
            core,
            model,
            commands,
            events,
            cancel,
            destroy,
            pending: VecDeque::new(),
            running: None,
            proposal: None,
            authorized: None,
        }
    }
    fn record(&mut self, kind: &str, request_id: Option<&str>, error: Option<String>) {
        let history = self.core.export_history();
        self.pending.push_back(json!({
            "version":1, "session_id":history.session_id,
            "turn_id":history.turns.last().map(|turn| turn.id),
            "operation_id":self.running.as_ref().map(|r| r.id).or(self.proposal),
            "type":kind, "request_id":request_id, "error":error,
            "events":self.core.take_events(), "history":history,
        }));
    }
    async fn cleanup(&mut self) {
        if let Some(running) = self.running.take() {
            if let Some(stop) = running.stop {
                let _ = stop.send(true);
            } else {
                running.task.abort();
            }
            // A tool task acknowledges only after group kill and child.wait().
            let _ = running.task.await;
        }
    }
    async fn stop(&mut self) {
        // A completed command may be waiting behind event backpressure. Preserve
        // its real result instead of replacing a known outcome with "unknown".
        if self
            .running
            .as_ref()
            .is_some_and(|r| r.stop.is_some() && r.task.is_finished())
        {
            let running = self.running.take().unwrap();
            if let Ok(Completion::Tool(result)) = running.task.await {
                let _ = self.core.complete_tool(running.id, result);
            }
        }
        self.core.cancel();
        self.cleanup().await;
        let _ = self.core.confirm_stopped();
        self.proposal = None;
        self.authorized = None;
    }
    fn command(&mut self, request: Request) {
        if request.cancel_generation != *self.cancel.borrow() {
            self.record(
                "command_result",
                Some(&request.request_id),
                Some("cancelled before processing".into()),
            );
            return;
        }
        let result = match request.command {
            Command::Submit { text } => self.core.submit(&text).map(|_| ()),
            Command::Steer { text } => {
                self.proposal = None;
                self.authorized = None;
                self.core.steer(&text).map(|_| ())
            }
            Command::ProvideDirectory { directory } => {
                self.proposal = None;
                self.authorized = None;
                self.core.provide_directory(directory)
            }
            Command::Continue => self.core.continue_turn().map(|_| ()),
            Command::ExportHistory => Ok(()),
            Command::StartTool { operation_id } => {
                if self.proposal == Some(operation_id) {
                    self.authorized = Some(operation_id);
                    Ok(())
                } else {
                    Err(mini_agent::Error::Config(
                        "stale or missing tool proposal".into(),
                    ))
                }
            }
        };
        self.record(
            "command_result",
            Some(&request.request_id),
            result.err().map(|e| e.to_string()),
        );
    }
    fn start_tool(&mut self, operation_id: u64) -> mini_agent::Result<()> {
        if self.proposal != Some(operation_id) {
            return Err(mini_agent::Error::Config(
                "stale or missing tool proposal".into(),
            ));
        }
        let operation = self.core.next_operation();
        if matches!(operation, Operation::WaitingForDirectory) {
            // Directory invalidation at the dispatch gate is a pause, not an
            // infrastructure failure. next_operation emitted DirectoryRequired.
            self.proposal = None;
            return Ok(());
        }
        let Operation::Tool {
            id,
            action,
            directory,
        } = operation
        else {
            self.proposal = None;
            return Err(mini_agent::Error::Config("tool no longer ready".into()));
        };
        self.core.begin_tool(id)?;
        let (stop, cancel) = watch::channel(false);
        self.running = Some(Running {
            id,
            stop: Some(stop),
            task: tokio::spawn(async move {
                Completion::Tool(crate::executor::execute(action, directory, cancel).await)
            }),
        });
        self.proposal = None;
        Ok(())
    }
    fn advance(&mut self) {
        if self.running.is_some() {
            return;
        }
        if let Some(id) = self.proposal {
            if self.authorized.take() == Some(id) {
                // run() drains all accepted controls before reaching this gate.
                let result = self.start_tool(id);
                if result.is_err() {
                    self.proposal = None;
                }
                self.record("update", None, result.err().map(|e| e.to_string()));
            }
            return;
        }
        match self.core.next_operation() {
            Operation::Model { id, history } => {
                let model = self.model.clone();
                self.running = Some(Running {
                    id,
                    stop: None,
                    task: tokio::spawn(async move {
                        Completion::Model(model.lock().await.query_conversation(&history).await)
                    }),
                });
                self.record("update", None, None);
            }
            Operation::Tool { id, .. } => {
                self.proposal = Some(id);
                self.record("tool_pending", None, None);
            }
            _ => {
                // next_operation may emit directory-required or budget terminal events.
                let events = self.core.take_events();
                if !events.is_empty() {
                    let history = self.core.export_history();
                    self.pending.push_back(json!({"version":1,"session_id":history.session_id,"type":"update","events":events,"history":history}));
                }
            }
        }
    }
    async fn run(mut self) {
        self.record("ready", None, None);
        loop {
            // No ordinary controls/operations advance while output is backpressured.
            // Stop and destruction have separate channels and always remain selectable.
            if *self.destroy.borrow() {
                self.stop().await;
                return;
            }
            if self.cancel.has_changed().unwrap_or(false) {
                self.cancel.borrow_and_update();
                self.stop().await;
                if !self.pending.iter().any(|p| p["type"] == "cancelled") {
                    self.record("cancelled", None, None);
                }
            }
            if !self.pending.is_empty() {
                let events = self.events.clone();
                tokio::select! {
                    biased;
                    _ = self.destroy.changed() => { self.stop().await; return; },
                    changed = self.cancel.changed() => {
                        if changed.is_err() { self.stop().await; return; }
                        self.stop().await;
                        // Repeated Stop does not accumulate unbounded terminal frames.
                        if !self.pending.iter().any(|p| p["type"] == "cancelled") { self.record("cancelled", None, None); }
                    },
                    permit = events.reserve_owned() => {
                        if let Ok(permit) = permit { permit.send(self.pending.pop_front().unwrap()); }
                        else { self.stop().await; return; }
                    },
                }
                continue;
            }
            // Drain accepted controls before completing a model or dispatching work.
            if let Ok(request) = self.commands.try_recv() {
                self.command(request);
                continue;
            }
            self.advance();
            if !self.pending.is_empty() {
                continue;
            }
            tokio::select! {
                biased;
                _ = self.destroy.changed() => { self.stop().await; return; },
                changed = self.cancel.changed() => {
                    if changed.is_err() { self.stop().await; return; }
                    self.stop().await; self.record("cancelled", None, None);
                },
                request = self.commands.recv() => {
                    if let Some(request) = request { self.command(request); }
                    else { self.stop().await; return; }
                },
                result = async { (&mut self.running.as_mut().unwrap().task).await }, if self.running.is_some() => {
                    let id = self.running.take().unwrap().id;
                    match result {
                        Ok(Completion::Model(result)) => { let _ = self.core.complete_model(id, result); },
                        Ok(Completion::Tool(result)) => { let _ = self.core.complete_tool(id, result); },
                        Err(_) => { self.core.cancel(); let _ = self.core.confirm_stopped(); },
                    }
                    self.record("update", None, None);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn queued_follow_up_revokes_tool_authorization_before_dispatch() {
        let temp = tempfile::tempdir().unwrap();
        let mut core =
            Conversation::new("gate", ConversationConfig::new("use bash when needed")).unwrap();
        core.provide_directory(Some(temp.path().into())).unwrap();
        core.submit("create a file").unwrap();
        let Operation::Model { id, .. } = core.next_operation() else {
            panic!("expected model")
        };
        let response: ConversationMessage = serde_json::from_value(json!({"message": {
            "role":"assistant", "tool_calls":[{"id":"call", "type":"function", "function":{
                "name":"bash", "arguments":"{\"command\":\"touch forbidden\"}"
            }}]
        }}))
        .unwrap();
        core.complete_model(id, Ok(response)).unwrap();
        let model = OpenAiModel::new(OpenAiConfig {
            base_url: "http://127.0.0.1:1".into(),
            model: "unused".into(),
            ..OpenAiConfig::default()
        })
        .unwrap();
        let (_commands, rx) = mpsc::channel(32);
        let (tx, _events) = mpsc::channel(64);
        let (_cancel, cancel) = watch::channel(0);
        let (_destroy, destroy) = watch::channel(false);
        let mut worker = Worker::new(
            core,
            Arc::new(tokio::sync::Mutex::new(model)),
            rx,
            tx,
            cancel,
            destroy,
        );
        worker.advance();
        let id = worker.proposal.unwrap();
        worker.command(Request {
            version: 1,
            request_id: "permission".into(),
            command: Command::StartTool { operation_id: id },
            cancel_generation: 0,
        });
        assert!(worker.running.is_none());
        worker.command(Request {
            version: 1,
            request_id: "follow-up".into(),
            command: Command::Steer {
                text: "do not create the file".into(),
            },
            cancel_generation: 0,
        });
        assert!(matches!(
            worker.core.next_operation(),
            Operation::Model { .. }
        ));
        assert!(worker.core.export_history().entries.iter().any(|entry| {
            serde_json::to_string(entry)
                .unwrap()
                .contains("not_executed")
        }));
        assert!(worker.running.is_none());
        assert!(!temp.path().join("forbidden").exists());
    }
}
