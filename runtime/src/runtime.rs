//! Timing and loop selection adapted from openai/codex codex-rs/tui/src/pets/ambient.rs.
use crate::model::{Animation, Pet};
use anyhow::{Result, ensure};
use std::time::Duration;

#[derive(Debug, PartialEq, Eq)]
pub struct FrameTick {
    pub sprite_index: usize,
    pub next_frame_in: Option<Duration>,
}

pub struct PetRuntime {
    pet: Pet,
    animation: String,
    base_animation: String,
    selected_animation: String,
    hovered: bool,
    direction: i32,
    look_frame: Option<usize>,
    started_at: Duration,
}

impl PetRuntime {
    pub fn look_at(&mut self, dx: f64, dy: f64, now: Duration) -> Result<()> {
        ensure!(
            dx.is_finite() && dy.is_finite(),
            "invalid pointer coordinates"
        );
        let look_frame = if self.pet.sprite_version_number == 2
            && self.pet.frame.columns == 8
            && self.pet.frame.rows >= 11
            && dx.hypot(dy) > 1.0
        {
            let angle = dx.atan2(-dy).to_degrees().rem_euclid(360.0);
            Some(72 + (angle / 22.5).round() as usize % 16)
        } else {
            None
        };
        if self.look_frame != look_frame {
            if self.can_look() {
                self.started_at = now;
            }
            self.look_frame = look_frame;
        }
        Ok(())
    }

    fn can_look(&self) -> bool {
        matches!(
            self.selected_animation.as_str(),
            "idle" | "running" | "waving"
        )
    }

    pub fn set_interaction(&mut self, hovered: bool, direction: i32, now: Duration) -> Result<()> {
        ensure!((-1..=1).contains(&direction), "invalid drag direction");
        self.hovered = hovered;
        self.direction = direction;
        self.select_animation(now, false);
        Ok(())
    }

    fn select_animation(&mut self, now: Duration, restart: bool) {
        let selected = match self.direction {
            -1 => "running-left",
            1 => "running-right",
            _ if self.hovered => "jumping",
            _ => &self.base_animation,
        };
        if self.selected_animation != selected || restart {
            self.animation = selected.into();
            self.selected_animation = selected.into();
            self.started_at = now;
        }
    }

    pub fn new(pet: Pet) -> Result<Self> {
        pet.validate_animations()?;
        Ok(Self {
            pet,
            animation: "idle".into(),
            base_animation: "idle".into(),
            selected_animation: "idle".into(),
            hovered: false,
            direction: 0,
            look_frame: None,
            started_at: Duration::ZERO,
        })
    }

    pub fn set_animation(&mut self, name: &str, now: Duration) -> Result<()> {
        ensure!(
            self.pet.animations.contains_key(name),
            "unknown animation: {name}"
        );
        self.base_animation = name.into();
        self.select_animation(now, !self.hovered && self.direction == 0);
        Ok(())
    }

    pub fn advance(&mut self, now: Duration) -> FrameTick {
        if self.can_look()
            && let Some(sprite_index) = self.look_frame
        {
            return FrameTick {
                sprite_index,
                next_frame_in: None,
            };
        }
        let mut elapsed = now.saturating_sub(self.started_at);
        loop {
            let animation = &self.pet.animations[&self.animation];
            let total = animation.total_duration();
            if animation.loop_start.is_none() && elapsed >= total {
                // Carry the overshoot into fallback instead of restarting it at
                // every tick. Validation guarantees the chain ends in a loop.
                elapsed -= total;
                self.started_at += total;
                self.animation = animation.fallback.clone();
            } else {
                return current_animation_frame(animation, elapsed);
            }
        }
    }
}

fn current_animation_frame(animation: &Animation, elapsed: Duration) -> FrameTick {
    let mut nanos = elapsed.as_nanos();
    if let Some(loop_start) = animation.loop_start {
        let prefix: u128 = animation.frames[..loop_start]
            .iter()
            .map(|f| f.duration.as_nanos())
            .sum();
        let cycle: u128 = animation.frames[loop_start..]
            .iter()
            .map(|f| f.duration.as_nanos())
            .sum();
        if nanos >= prefix {
            nanos = prefix + (nanos - prefix) % cycle;
        }
    }
    for (index, frame) in animation.frames.iter().enumerate() {
        let duration = frame.duration.as_nanos();
        if nanos < duration {
            let static_tail =
                animation.loop_start == Some(index) && index + 1 == animation.frames.len();
            let remaining = duration - nanos;
            return FrameTick {
                sprite_index: frame.sprite_index,
                next_frame_in: (!static_tail).then(|| {
                    Duration::new(
                        (remaining / 1_000_000_000) as u64,
                        (remaining % 1_000_000_000) as u32,
                    )
                }),
            };
        }
        nanos -= duration;
    }
    unreachable!("validated animation and normalized elapsed always select a frame")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn bundled_planets_share_continuous_voice_animations() {
        for name in ["ember-planet", "quiet-planet"] {
            let directory = Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../assets/planets")
                .join(name);
            let pet = Pet::load(&directory).unwrap();
            let running = &pet.animations["running"];
            assert_eq!(running.loop_start, Some(0));
            assert!((56..=61).contains(&current_animation_frame(running, Duration::from_secs(10)).sprite_index));
            let spinning = &pet.animations["spinning"];
            assert_eq!(spinning.loop_start, Some(0));
            assert_eq!(spinning.frames.iter().map(|f| f.sprite_index).collect::<Vec<_>>(),
                       (72..=87).collect::<Vec<_>>());
            assert_eq!(current_animation_frame(spinning, Duration::from_millis(1920)).sprite_index, 72);
            let mut runtime = PetRuntime::new(pet).unwrap();
            runtime.look_at(100.0, 0.0, Duration::ZERO).unwrap();
            assert_eq!(runtime.advance(Duration::ZERO).sprite_index, 76);
            runtime.set_animation("spinning", Duration::ZERO).unwrap();
            assert_eq!(runtime.advance(Duration::ZERO).sprite_index, 72);
        }
    }
}
