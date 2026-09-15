//! Host initialization/runtime adaptation only. Mini Agent owns all dispatch,
//! checkpoint gates, cancellation and process cleanup.
use crate::wire::{HistoryInput, Protocol, RestoreInput, WireCreate};
use mini_agent::{
    conversation::{Conversation, ConversationConfig, runner::*},
    models::{ApiProtocol, OpenAiConfig, OpenAiModel},
};
use std::{
    sync::{
        OnceLock,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::runtime::Runtime;

pub static ACTIVE: AtomicUsize = AtomicUsize::new(0);
static RUNTIME: OnceLock<Result<Runtime, SessionError>> = OnceLock::new();

fn runtime() -> SessionResult<&'static Runtime> {
    RUNTIME
        .get_or_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .thread_name("echo-agent")
                .enable_all()
                .build()
                .map_err(|_| SessionError::new(ErrorCode::Internal, "cannot create agent runtime"))
        })
        .as_ref()
        .map_err(Clone::clone)
}

struct Count;
impl Drop for Count {
    fn drop(&mut self) {
        ACTIVE.fetch_sub(1, Ordering::SeqCst);
    }
}

pub fn spawn(config: WireCreate) -> SessionResult<SessionHandle> {
    let runtime = runtime()?;
    let options = SessionOptions::new(&config.session_id, &config.generation);
    let handle = mini_agent::conversation::runner::spawn(
        runtime.handle(),
        async move {
            // Always await blocking work, even after close/Stop. Completion must
            // never claim cleanup while prompt/client initialization is running.
            tokio::task::spawn_blocking(move || initialize(config))
                .await
                .map_err(|_| initialization_error())?
        },
        options,
    )?;
    let completion = handle.completion();
    ACTIVE.fetch_add(1, Ordering::SeqCst);
    let count = Count;
    runtime.spawn(async move {
        let _count = count;
        completion.wait().await;
    });
    Ok(handle)
}

fn initialization_error() -> SessionError {
    // Never include paths, credentials, full config or provider responses.
    SessionError::new(
        ErrorCode::InitializationFailed,
        "agent initialization failed",
    )
}

fn initialize(
    config: WireCreate,
) -> SessionResult<SessionParts<OpenAiModel, LocalConversationExecutor>> {
    let prompt = std::fs::read_to_string(config.prompt_path).map_err(|_| initialization_error())?;
    let source = match config.restore.source {
        HistoryInput::Empty {} => HistoryInput::Empty {},
        HistoryInput::LegacyText { messages } => HistoryInput::LegacyText { messages },
        HistoryInput::V1 { history } => HistoryInput::V1 {
            history: serde_json::from_str(&history).map_err(|_| {
                SessionError::new(ErrorCode::InvalidHistory, "invalid conversation history")
            })?,
        },
    };
    let restored = Conversation::restore(
        config.session_id,
        ConversationConfig::new(prompt),
        RestoreInput {
            source,
            input_receipts: config.restore.input_receipts,
            pending_inputs: config.restore.pending_inputs,
            directory: config.restore.directory,
        },
    )?;
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
    )
    .map_err(|_| initialization_error())?;
    let executor = LocalConversationExecutor::new(LocalExecutorConfig {
        shell: "/bin/bash".into(),
        timeout: Duration::from_secs(30),
        max_output_bytes: 64 * 1024,
        ..Default::default()
    })?;
    Ok(SessionParts {
        restored,
        model,
        executor,
    })
}
