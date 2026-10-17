//! Manifest and animation semantics adapted from openai/codex codex-rs/tui/src/pets/model.rs.
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, bail, ensure};
use serde::Deserialize;

#[derive(Debug, Clone)]
pub struct AnimationFrame {
    pub sprite_index: usize,
    pub duration: Duration,
}

#[derive(Debug, Clone)]
pub struct Animation {
    pub frames: Vec<AnimationFrame>,
    pub loop_start: Option<usize>,
    pub fallback: String,
}

impl Animation {
    pub fn total_duration(&self) -> Duration {
        self.frames.iter().map(|frame| frame.duration).sum()
    }
}

#[derive(Debug, Clone, Copy, Deserialize)]
pub struct FrameSpec {
    pub width: u32,
    pub height: u32,
    pub columns: u32,
    pub rows: u32,
}

#[derive(Debug)]
pub struct Pet {
    pub id: String,
    pub display_name: String,
    pub spritesheet_path: PathBuf,
    pub frame: FrameSpec,
    pub animations: HashMap<String, Animation>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PetFile {
    id: String,
    display_name: String,
    sprite_version_number: Option<u32>,
    #[serde(default = "default_spritesheet")]
    spritesheet_path: String,
    frame: Option<FrameSpec>,
    #[serde(default)]
    animations: HashMap<String, AnimationSpec>,
}

fn default_spritesheet() -> String {
    "spritesheet.webp".into()
}

#[derive(Deserialize)]
struct AnimationSpec {
    frames: Vec<usize>,
    fps: Option<f64>,
    #[serde(rename = "loop")]
    looping: Option<bool>,
    #[serde(default)]
    fallback: String,
}

impl Pet {
    pub fn load(directory: &Path) -> Result<Self> {
        let path = directory.join("pet.json");
        let raw = fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?;
        Self::from_manifest(directory, &raw)
    }

    fn from_manifest(directory: &Path, raw: &str) -> Result<Self> {
        let file: PetFile = serde_json::from_str(raw).context("parse pet.json")?;
        // Only the 11-row sheet with look directions. A manifest without the field is the older
        // 9-row format, which is not read.
        match file.sprite_version_number {
            Some(2) => {}
            Some(version) => bail!("unsupported spriteVersionNumber: {version}"),
            None => bail!("spriteVersionNumber is missing; only version 2 is supported"),
        }
        let frame = file.frame.unwrap_or(FrameSpec {
            width: 192,
            height: 208,
            columns: 8,
            rows: 11,
        });
        ensure!(
            frame.width > 0 && frame.height > 0 && frame.columns > 0 && frame.rows > 0,
            "frame dimensions and grid counts must be positive"
        );
        let count = frame
            .columns
            .checked_mul(frame.rows)
            .context("frame count overflow")?;
        ensure!(count <= 256, "pet frame count exceeds 256");
        frame
            .width
            .checked_mul(frame.columns)
            .context("sheet width overflow")?;
        frame
            .height
            .checked_mul(frame.rows)
            .context("sheet height overflow")?;
        let relative_path = Path::new(&file.spritesheet_path);
        ensure!(
            !relative_path.as_os_str().is_empty()
                && !relative_path.is_absolute()
                && !relative_path
                    .components()
                    .any(|c| matches!(c, Component::ParentDir | Component::Prefix(_))),
            "spritesheetPath must be a relative child path"
        );

        let mut animations = default_animations();
        if has_look_frames(frame) {
            animations.insert(
                "spinning".into(),
                looping(
                    (72..=87)
                        .map(|sprite_index| AnimationFrame {
                            sprite_index,
                            duration: Duration::from_millis(120),
                        })
                        .collect(),
                ),
            );
        }
        for (name, spec) in file.animations {
            let fps = spec.fps.unwrap_or(8.0);
            ensure!(
                fps.is_finite() && fps > 0.0 && fps <= 60.0,
                "invalid fps for {name}"
            );
            let duration =
                Duration::try_from_secs_f64(1.0 / fps).context("frame duration out of range")?;
            animations.insert(
                name,
                Animation {
                    frames: spec
                        .frames
                        .into_iter()
                        .map(|sprite_index| AnimationFrame {
                            sprite_index,
                            duration,
                        })
                        .collect(),
                    loop_start: spec.looping.unwrap_or(true).then_some(0),
                    fallback: if spec.fallback.is_empty() {
                        "idle".into()
                    } else {
                        spec.fallback
                    },
                },
            );
        }
        let pet = Self {
            id: file.id,
            display_name: file.display_name,
            spritesheet_path: directory.join(relative_path),
            frame,
            animations,
        };
        pet.validate_animations()?;
        Ok(pet)
    }

    pub fn frame_count(&self) -> usize {
        (self.frame.columns * self.frame.rows) as usize
    }

    /// Whether the sheet has the 16 look directions, frames 72 to 87.
    pub fn has_look_frames(&self) -> bool {
        has_look_frames(self.frame)
    }

    pub fn validate_animations(&self) -> Result<()> {
        ensure!(
            self.animations.contains_key("idle"),
            "missing idle animation"
        );
        for (name, animation) in &self.animations {
            ensure!(
                !animation.frames.is_empty(),
                "animation {name} has no frames"
            );
            ensure!(
                animation.frames.len() <= 1024,
                "animation {name} has too many frames"
            );
            ensure!(
                animation
                    .loop_start
                    .is_none_or(|start| start < animation.frames.len()),
                "invalid loop_start for {name}"
            );
            ensure!(
                self.animations.contains_key(&animation.fallback),
                "missing fallback for {name}"
            );
            let mut total = Duration::ZERO;
            for frame in &animation.frames {
                ensure!(
                    frame.sprite_index < self.frame_count(),
                    "sprite index out of range in {name}"
                );
                ensure!(!frame.duration.is_zero(), "zero frame duration in {name}");
                total = total
                    .checked_add(frame.duration)
                    .context("animation duration overflow")?;
            }
            // A one-shot chain must eventually reach a loop. This bounds advance()
            // even after a long suspension, including single-frame one-shots.
            let mut visited = HashSet::new();
            let mut current = name.as_str();
            loop {
                let track = self
                    .animations
                    .get(current)
                    .context("missing fallback animation")?;
                if track.loop_start.is_some() {
                    break;
                }
                ensure!(
                    visited.insert(current),
                    "one-shot fallback cycle at {current}"
                );
                current = &track.fallback;
            }
        }
        Ok(())
    }
}

fn idle_animation() -> Animation {
    Animation {
        frames: [(0, 1680), (1, 660), (2, 660), (3, 840), (4, 840), (5, 1920)]
            .into_iter()
            .map(|(sprite_index, ms)| AnimationFrame {
                sprite_index,
                duration: Duration::from_millis(ms),
            })
            .collect(),
        loop_start: Some(0),
        fallback: "idle".into(),
    }
}

/// One row of the standard sheet, holding `final_ms` on its last frame.
fn row_frames(row: usize, count: usize, ms: u64, final_ms: u64) -> Vec<AnimationFrame> {
    (0..count)
        .map(|column| AnimationFrame {
            sprite_index: row * 8 + column,
            duration: Duration::from_millis(if column + 1 == count { final_ms } else { ms }),
        })
        .collect()
}

/// A sheet with its own grid keeps the look directions only where the standard one has them.
fn has_look_frames(frame: FrameSpec) -> bool {
    frame.columns == 8 && frame.rows >= 11
}

/// Cycles its frames for as long as the state lasts.
fn looping(frames: Vec<AnimationFrame>) -> Animation {
    Animation {
        frames,
        loop_start: Some(0),
        fallback: "idle".into(),
    }
}

fn app_state_animation(row: usize, count: usize, ms: u64, final_ms: u64) -> Animation {
    three_runs(row_frames(row, count, ms, final_ms))
}

/// Reference behavior: play the action three times, then loop the idle tail.
fn three_runs(primary: Vec<AnimationFrame>) -> Animation {
    let count = primary.len();
    Animation {
        frames: primary
            .iter()
            .cycle()
            .take(count * 3)
            .cloned()
            .chain(idle_animation().frames)
            .collect(),
        loop_start: Some(count * 3),
        fallback: "idle".into(),
    }
}

/// The working row, shared by Live Voice's thinking and the pet's task.
fn running_frames() -> Vec<AnimationFrame> {
    row_frames(7, 6, 120, 220)
}

fn default_animations() -> HashMap<String, Animation> {
    let mut animations = HashMap::from([("idle".into(), idle_animation())]);
    for (name, row, count, ms, final_ms) in [
        ("running-right", 1, 8, 120, 220),
        ("running-left", 2, 8, 120, 220),
        ("waving", 3, 4, 140, 280),
        ("jumping", 4, 5, 140, 280),
        ("failed", 5, 8, 140, 240),
        ("waiting", 6, 6, 150, 260),
        ("review", 8, 6, 150, 280),
    ] {
        animations.insert(name.into(), app_state_animation(row, count, ms, final_ms));
    }
    // Live Voice thinking lasts as long as the agent runs; keep this state cycling.
    animations.insert("running".into(), looping(running_frames()));
    // The pet's task starting is told three times like the other states, then rests.
    animations.insert("task-running".into(), three_runs(running_frames()));
    for (alias, name) in [
        ("move_right", "running-right"),
        ("move_left", "running-left"),
        ("wave", "waving"),
        ("bounce", "jumping"),
        ("sad", "failed"),
    ] {
        animations.insert(alias.into(), animations[name].clone());
    }
    animations
}
