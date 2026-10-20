//! Timing and loop selection adapted from openai/codex codex-rs/tui/src/pets/ambient.rs.
//! What shows over what (drag, a one-shot, hovering, looking at the pointer) is Echo's own;
//! see `PetRuntime::shown`.
use crate::model::{Animation, LOOK_FRAMES, Pet, span};
use anyhow::{Result, ensure};
use std::time::Duration;

/// How long an idle pet keeps facing the pointer after it last moved.
pub const LOOK_HOLD: Duration = Duration::from_secs(2);

#[derive(Debug, PartialEq, Eq)]
pub struct FrameTick {
    pub sprite_index: usize,
    pub next_frame_in: Option<Duration>,
}

/// A clip shown from `started_at` until `ends_at`: a click's wave, or the jump on hovering.
struct Once {
    name: String,
    started_at: Duration,
    ends_at: Duration,
    /// The hover jump, which the pointer leaving cuts short.
    ends_on_leave: bool,
}

impl Once {
    fn new(pet: &Pet, name: &str, now: Duration, ends_on_leave: bool) -> Self {
        Self {
            name: name.into(),
            started_at: now,
            ends_at: now + once_length(&pet.animations[name]),
            ends_on_leave,
        }
    }

    fn is_playing(&self, now: Duration) -> bool {
        now < self.ends_at
    }

    fn frame(&self, pet: &Pet, now: Duration) -> FrameTick {
        let mut tick = frame_at(pet, &self.name, now.saturating_sub(self.started_at));
        // Wake when it ends, so what lies under it shows on time.
        let left = self.ends_at - now;
        tick.next_frame_in = Some(tick.next_frame_in.map_or(left, |next| next.min(left)));
        tick
    }
}

/// What the pet shows, in priority order.
enum Shown<'a> {
    Run(&'static str),
    Clip(&'a Once),
    Look(usize, Duration),
    Base,
}

pub struct PetRuntime {
    pet: Pet,
    /// The state the app sets: idle, a task's state on the pet, or a Live Voice state on a planet.
    base: String,
    /// None while a state set under something else waits to show for the first time.
    base_started_at: Option<Duration>,
    /// A clip played once over everything but a drag: a click's wave, or the jump that greets
    /// the pointer each time it enters.
    clip: Option<Once>,
    hovered: bool,
    direction: i32,
    drag_started_at: Duration,
    /// The last pointer offset, and when it last changed.
    pointer: Option<((f64, f64), Duration)>,
}

impl PetRuntime {
    pub fn new(pet: Pet) -> Result<Self> {
        pet.validate_animations()?;
        Ok(Self {
            pet,
            base: "idle".into(),
            base_started_at: Some(Duration::ZERO),
            clip: None,
            hovered: false,
            direction: 0,
            drag_started_at: Duration::ZERO,
            pointer: None,
        })
    }

    pub fn look_at(&mut self, dx: f64, dy: f64, now: Duration) -> Result<()> {
        ensure!(
            dx.is_finite() && dy.is_finite(),
            "invalid pointer coordinates"
        );
        // The same offset again is not a move, so it does not keep the pet looking.
        if self.pointer.is_none_or(|(offset, _)| offset != (dx, dy)) {
            self.pointer = Some(((dx, dy), now));
        }
        Ok(())
    }

    /// The look sprite facing `(dx, dy)`, outside a 1 pt dead zone at the center.
    fn look_sprite(&self, dx: f64, dy: f64) -> Option<usize> {
        if !self.pet.frame.has_look_frames() || dx.hypot(dy) <= 1.0 {
            return None;
        }
        let angle = dx.atan2(-dy).to_degrees().rem_euclid(360.0);
        Some(LOOK_FRAMES.start + (angle / 22.5).round() as usize % LOOK_FRAMES.len())
    }

    pub fn set_interaction(&mut self, hovered: bool, direction: i32, now: Duration) -> Result<()> {
        ensure!((-1..=1).contains(&direction), "invalid drag direction");
        // Entering during a drag, or in the call that ends it, is the drag's own doing.
        let dragging = self.direction != 0 || direction != 0;
        let waving = self.clip.as_ref().is_some_and(|clip| clip.is_playing(now));
        if hovered && !self.hovered && !dragging && !waving {
            self.clip = Some(Once::new(&self.pet, "jumping", now, true));
        }
        if !hovered && self.clip.as_ref().is_some_and(|clip| clip.ends_on_leave) {
            self.clip = None;
        }
        if direction != 0 && direction != self.direction {
            // Running starts over when a drag starts or turns, and ends a wave or a jump.
            self.drag_started_at = now;
            self.clip = None;
        }
        self.hovered = hovered;
        self.direction = direction;
        Ok(())
    }

    /// Sets the pet's state. It starts now if nothing covers it, as a Live Voice planet never is;
    /// otherwise when it first shows, so a drag, a wave or a jump does not use up its start.
    pub fn set_animation(&mut self, name: &str, now: Duration) -> Result<()> {
        ensure!(
            self.pet.animations.contains_key(name),
            "unknown animation: {name}"
        );
        self.base = name.into();
        // Unstarted while it is judged, so the old state's time never counts toward the new one.
        self.base_started_at = None;
        self.base_started_at = matches!(self.shown(now), Shown::Base).then_some(now);
        Ok(())
    }

    /// Plays `name` once over the pet's state, as a click does with the wave. Hovering and the
    /// pointer cannot cut it short; a drag ends it.
    pub fn play_once(&mut self, name: &str, now: Duration) -> Result<()> {
        ensure!(
            self.pet.animations.contains_key(name),
            "unknown animation: {name}"
        );
        // It takes over from the jump that greeted the pointer, which does not come back after.
        self.clip = Some(Once::new(&self.pet, name, now, false));
        Ok(())
    }

    /// Idle lets the pet look at the pointer, and so does a state that has played its runs and
    /// rests in its idle tail. One that only loops, as Live Voice's do, never does.
    fn base_takes_look(&self, now: Duration) -> bool {
        self.base == "idle"
            || self.base_started_at.is_some_and(|started_at| {
                let animation = &self.pet.animations[&self.base];
                animation.loop_start.is_some_and(|start| start > 0)
                    && now >= started_at + once_length(animation)
            })
    }

    /// The one place that orders what the pet shows: a drag, then a one-shot, then hovering,
    /// then looking at a pointer that moved in the last `LOOK_HOLD`, then the state the app set.
    fn shown(&self, now: Duration) -> Shown<'_> {
        if self.direction != 0 {
            return Shown::Run(if self.direction < 0 {
                "running-left"
            } else {
                "running-right"
            });
        }
        if let Some(clip) = &self.clip
            && clip.is_playing(now)
        {
            return Shown::Clip(clip);
        }
        if self.hovered {
            // A pointer resting on the pet is not looked at.
            return Shown::Base;
        }
        if self.base_takes_look(now)
            && let Some(((dx, dy), moved_at)) = self.pointer
            && now < moved_at + LOOK_HOLD
            && let Some(sprite_index) = self.look_sprite(dx, dy)
        {
            return Shown::Look(sprite_index, moved_at + LOOK_HOLD);
        }
        Shown::Base
    }

    pub fn advance(&mut self, now: Duration) -> FrameTick {
        match self.shown(now) {
            Shown::Run(name) => {
                return frame_at(&self.pet, name, now.saturating_sub(self.drag_started_at));
            }
            Shown::Clip(clip) => return clip.frame(&self.pet, now),
            // A held pose that wakes once the pointer has been still for LOOK_HOLD.
            Shown::Look(sprite_index, until) => {
                return FrameTick {
                    sprite_index,
                    next_frame_in: Some(until - now),
                };
            }
            Shown::Base => {}
        }
        let started_at = *self.base_started_at.get_or_insert(now);
        frame_at(&self.pet, &self.base, now.saturating_sub(started_at))
    }
}

/// The part of a clip a one-shot plays: a standard clip's three runs before its idle tail. A clip
/// that loops from its first frame, or never loops, plays through once.
fn once_length(animation: &Animation) -> Duration {
    let end = animation
        .loop_start
        .filter(|&start| start > 0)
        .unwrap_or(animation.frames.len());
    span(&animation.frames[..end])
}

/// The frame `elapsed` into `name`, carrying the overshoot of each finished one-shot into its
/// fallback. Validation guarantees the chain ends in a loop.
fn frame_at(pet: &Pet, name: &str, mut elapsed: Duration) -> FrameTick {
    let mut animation = &pet.animations[name];
    while animation.loop_start.is_none() && elapsed >= animation.total_duration() {
        elapsed -= animation.total_duration();
        animation = &pet.animations[&animation.fallback];
    }
    current_animation_frame(animation, elapsed)
}

fn current_animation_frame(animation: &Animation, elapsed: Duration) -> FrameTick {
    let mut nanos = elapsed.as_nanos();
    if let Some(loop_start) = animation.loop_start {
        let prefix = span(&animation.frames[..loop_start]).as_nanos();
        let cycle = span(&animation.frames[loop_start..]).as_nanos();
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
                next_frame_in: (!static_tail).then(|| Duration::from_nanos_u128(remaining)),
            };
        }
        nanos -= duration;
    }
    unreachable!("validated animation and normalized elapsed always select a frame")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::uniform;
    use std::ops::RangeInclusive;
    use std::path::Path;

    // Rows of the standard sheet.
    const IDLE: RangeInclusive<usize> = 0..=5;
    const RUN_RIGHT: RangeInclusive<usize> = 8..=15;
    const RUN_LEFT: RangeInclusive<usize> = 16..=23;
    const WAVE: RangeInclusive<usize> = 24..=27;
    const JUMP: RangeInclusive<usize> = 32..=36;
    const FAILED: RangeInclusive<usize> = 40..=47;
    const RUNNING: RangeInclusive<usize> = 56..=61;
    const REVIEW: RangeInclusive<usize> = 64..=69;
    const LOOK: RangeInclusive<usize> = 72..=87;

    fn load(kind: &str, name: &str) -> Pet {
        Pet::load(
            &Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../assets")
                .join(kind)
                .join(name),
        )
        .unwrap()
    }

    fn pet() -> PetRuntime {
        PetRuntime::new(load("pets", "chiyan")).unwrap()
    }

    fn ms(millis: u64) -> Duration {
        Duration::from_millis(millis)
    }

    fn sprite(runtime: &mut PetRuntime, at: u64) -> usize {
        runtime.advance(ms(at)).sprite_index
    }

    fn blink() -> Animation {
        Animation {
            frames: uniform([0, 1], ms(100)),
            loop_start: None,
            fallback: "running".into(),
        }
    }

    #[test]
    fn bundled_planets_share_continuous_voice_animations() {
        for name in ["ember-planet", "quiet-planet"] {
            let pet = load("planets", name);
            let running = &pet.animations["running"];
            assert_eq!(running.loop_start, Some(0));
            assert!((56..=61).contains(&current_animation_frame(running, ms(10_000)).sprite_index));
            let spinning = &pet.animations["spinning"];
            assert_eq!(spinning.loop_start, Some(0));
            assert_eq!(spinning.frames.iter().map(|f| f.sprite_index).collect::<Vec<_>>(),
                       (72..=87).collect::<Vec<_>>());
            assert_eq!(current_animation_frame(spinning, ms(1920)).sprite_index, 72);
            let mut runtime = PetRuntime::new(pet).unwrap();
            runtime.look_at(100.0, 0.0, Duration::ZERO).unwrap();
            assert_eq!(runtime.advance(Duration::ZERO).sprite_index, 76);
            runtime.set_animation("spinning", Duration::ZERO).unwrap();
            assert_eq!(runtime.advance(Duration::ZERO).sprite_index, 72);
        }
    }

    #[test]
    fn idle_returns_after_the_pointer_rests() {
        let mut runtime = pet();
        runtime.look_at(300.0, 0.0, ms(0)).unwrap();
        assert_eq!(
            runtime.advance(ms(0)),
            FrameTick { sprite_index: 76, next_frame_in: Some(LOOK_HOLD) },
            "A moving pointer turns the pet, which wakes when the hold runs out"
        );
        assert_eq!(sprite(&mut runtime, 1999), 76);
        // Idle kept its own time underneath: 2 s in is its second frame, 340 ms before the third.
        assert_eq!(
            runtime.advance(ms(2000)),
            FrameTick { sprite_index: 1, next_frame_in: Some(ms(340)) }
        );
        assert_eq!(sprite(&mut runtime, 2340), 2, "Idle keeps playing with the pointer still");
        assert!(IDLE.contains(&sprite(&mut runtime, 600_000)), "Minutes later it is still idle");
    }

    #[test]
    fn only_a_moving_pointer_extends_the_look() {
        let mut runtime = pet();
        runtime.look_at(300.0, 0.0, ms(0)).unwrap();
        runtime.look_at(300.0, 0.0, ms(1500)).unwrap();
        assert!(IDLE.contains(&sprite(&mut runtime, 2000)), "The same offset again is not a move");
        runtime.look_at(0.0, -300.0, ms(2500)).unwrap();
        assert_eq!(
            runtime.advance(ms(3000)),
            FrameTick { sprite_index: 72, next_frame_in: Some(ms(1500)) }
        );
        assert_eq!(sprite(&mut runtime, 4499), 72);
        assert!(IDLE.contains(&sprite(&mut runtime, 4500)));
    }

    #[test]
    fn look_frames_follow_sixteen_directions() {
        let mut runtime = pet();
        for (step, (dx, dy, expected)) in [
            (0.0, -300.0, 72),
            (300.0, -300.0, 74),
            (300.0, 0.0, 76),
            (0.0, 300.0, 80),
            (-300.0, 0.0, 84),
            (-300.0, -300.0, 86),
        ]
        .into_iter()
        .enumerate()
        {
            let at = step as u64 * 100;
            runtime.look_at(dx, dy, ms(at)).unwrap();
            assert_eq!(sprite(&mut runtime, at), expected, "offset ({dx}, {dy})");
        }
        runtime.look_at(0.5, 0.5, ms(700)).unwrap();
        assert!(IDLE.contains(&sprite(&mut runtime, 700)), "The center's 1 pt dead zone shows idle");
    }

    #[test]
    fn click_wave_plays_in_full_over_hover_and_look() {
        let mut runtime = pet();
        runtime.look_at(10.0, 10.0, ms(0)).unwrap();
        runtime.set_interaction(true, 0, ms(0)).unwrap();
        assert!(JUMP.contains(&sprite(&mut runtime, 100)), "Entering jumps");
        runtime.play_once("waving", ms(500)).unwrap();
        assert_eq!(
            runtime.advance(ms(500)),
            FrameTick { sprite_index: 24, next_frame_in: Some(ms(140)) },
            "A click waves over the hover jump"
        );
        // The pointer leaves halfway through; the wave plays on.
        runtime.set_interaction(false, 0, ms(1000)).unwrap();
        runtime.look_at(300.0, 0.0, ms(1000)).unwrap();
        assert!(WAVE.contains(&sprite(&mut runtime, 1000)));
        assert_eq!(sprite(&mut runtime, 2599), 27, "The third wave's last frame");
        assert_eq!(sprite(&mut runtime, 2600), 76, "Then the pet faces the pointer that moved");
        assert!(IDLE.contains(&sprite(&mut runtime, 3000)), "And rests 2 s after it stopped");
    }

    #[test]
    fn the_wave_never_replays() {
        let mut runtime = pet();
        runtime.play_once("waving", ms(0)).unwrap();
        assert!(WAVE.contains(&sprite(&mut runtime, 0)));
        let events: [(u64, bool, i32); 6] = [
            (3000, true, 0),
            (3500, false, 0),
            (4000, true, 0),
            (4100, true, 1),
            (5000, true, 0),
            (5100, false, 0),
        ];
        for at in (2100..8000).step_by(50) {
            for (time, hovered, direction) in events {
                if time == at {
                    runtime.set_interaction(hovered, direction, ms(at)).unwrap();
                    runtime.look_at(300.0, at as f64, ms(at)).unwrap();
                }
            }
            assert!(!WAVE.contains(&sprite(&mut runtime, at)), "No wave at {at} ms");
        }
    }

    #[test]
    fn hover_jumps_once_per_entry() {
        let mut runtime = pet();
        runtime.set_interaction(true, 0, ms(0)).unwrap();
        assert_eq!(sprite(&mut runtime, 0), 32);
        assert!(JUMP.contains(&sprite(&mut runtime, 2519)));
        // A pointer moving on the pet is not looked at; idle shows once the jump is done.
        runtime.look_at(10.0, -40.0, ms(2500)).unwrap();
        assert_eq!(sprite(&mut runtime, 2520), 2, "Idle's third frame, on its own clock");
        runtime.set_interaction(false, 0, ms(3000)).unwrap();
        runtime.look_at(300.0, 0.0, ms(3000)).unwrap();
        assert_eq!(sprite(&mut runtime, 3000), 76, "Leaving turns the pet to the pointer");
        runtime.set_interaction(true, 0, ms(4000)).unwrap();
        assert_eq!(sprite(&mut runtime, 4000), 32, "Entering again jumps again");
        runtime.set_interaction(false, 0, ms(4300)).unwrap();
        runtime.look_at(300.0, 1.0, ms(4300)).unwrap();
        assert_eq!(sprite(&mut runtime, 4300), 76, "Leaving cuts the jump short");
    }

    #[test]
    fn drag_runs_over_everything_and_ends_the_wave() {
        let mut runtime = pet();
        runtime.set_interaction(true, 0, ms(0)).unwrap();
        runtime.play_once("waving", ms(100)).unwrap();
        runtime.set_interaction(true, 1, ms(300)).unwrap();
        assert_eq!(
            runtime.advance(ms(300)),
            FrameTick { sprite_index: 8, next_frame_in: Some(ms(120)) }
        );
        assert_eq!(sprite(&mut runtime, 420), 9);
        assert!(RUN_RIGHT.contains(&sprite(&mut runtime, 499)));
        runtime.set_interaction(true, -1, ms(500)).unwrap();
        assert_eq!(sprite(&mut runtime, 500), 16, "Turning starts the other run over");
        assert!(RUN_LEFT.contains(&sprite(&mut runtime, 900)));
        runtime.set_interaction(true, 0, ms(1000)).unwrap();
        assert_eq!(sprite(&mut runtime, 1000), 0, "Dropped on the pet: idle, no rest of the wave, no jump");
    }

    #[test]
    fn entering_during_a_drag_does_not_jump() {
        let mut runtime = pet();
        runtime.set_interaction(true, 0, ms(0)).unwrap();
        runtime.set_interaction(true, 1, ms(200)).unwrap();
        runtime.set_interaction(false, 1, ms(300)).unwrap();
        runtime.set_interaction(true, 1, ms(350)).unwrap();
        runtime.set_interaction(false, 1, ms(400)).unwrap();
        // The call that ends the drag also finds the pointer back on the pet.
        runtime.set_interaction(true, 0, ms(500)).unwrap();
        assert_eq!(sprite(&mut runtime, 500), 0);
        assert!(IDLE.contains(&sprite(&mut runtime, 1500)));
    }

    #[test]
    fn look_never_covers_other_bases() {
        for (name, frames) in [("running", 56..=61), ("failed", 40..=47)] {
            let mut runtime = pet();
            runtime.set_animation(name, ms(0)).unwrap();
            runtime.look_at(300.0, 0.0, ms(100)).unwrap();
            assert!(frames.contains(&sprite(&mut runtime, 100)), "{name} shows under a moving pointer");
            if name == "running" {
                runtime.look_at(300.0, 1.0, ms(10_000)).unwrap();
                assert!(frames.contains(&sprite(&mut runtime, 10_000)), "Looping, running never rests");
            }
            // Back to idle while the pointer moves: the look shows, and idle starts after it.
            runtime.look_at(300.0, 5.0, ms(200)).unwrap();
            runtime.set_animation("idle", ms(200)).unwrap();
            assert!(LOOK.contains(&sprite(&mut runtime, 200)));
            assert_eq!(
                runtime.advance(ms(2200)),
                FrameTick { sprite_index: 0, next_frame_in: Some(ms(1680)) }
            );
        }
    }

    #[test]
    fn task_running_plays_three_runs_then_rests() {
        let mut runtime = pet();
        runtime.set_animation("task-running", ms(0)).unwrap();
        assert_eq!(runtime.advance(ms(0)), FrameTick { sprite_index: 56, next_frame_in: Some(ms(120)) });
        assert_eq!(sprite(&mut runtime, 820), 56, "The second run");
        assert!(RUNNING.contains(&sprite(&mut runtime, 2459)));
        assert_eq!(
            runtime.advance(ms(2460)),
            FrameTick { sprite_index: 0, next_frame_in: Some(ms(1680)) },
            "Three runs, then the idle tail"
        );
        assert_eq!(once_length(&runtime.pet.animations["task-running"]), ms(2460));
    }

    #[test]
    fn look_returns_once_a_state_has_played_its_runs() {
        for (name, frames, runs) in [("task-running", RUNNING, 2460), ("review", REVIEW, 3090), ("failed", FAILED, 3660)] {
            let mut runtime = pet();
            runtime.set_animation(name, ms(0)).unwrap();
            runtime.look_at(300.0, 0.0, ms(runs - 1)).unwrap();
            assert!(frames.contains(&sprite(&mut runtime, runs - 1)), "{name}'s last run shows under a moving pointer");
            runtime.look_at(0.0, -300.0, ms(runs)).unwrap();
            assert_eq!(
                runtime.advance(ms(runs)),
                FrameTick { sprite_index: 72, next_frame_in: Some(LOOK_HOLD) },
                "Resting after {name}, the pet faces the pointer"
            );
            // The idle tail kept its own time: 2 s into it is its second frame, as for idle.
            assert_eq!(
                runtime.advance(ms(runs + 2000)),
                FrameTick { sprite_index: 1, next_frame_in: Some(ms(340)) }
            );
        }
    }

    #[test]
    fn a_state_set_while_the_pet_looks_starts_at_once() {
        let mut runtime = pet();
        runtime.look_at(300.0, 0.0, ms(0)).unwrap();
        runtime.set_animation("task-running", ms(500)).unwrap();
        assert_eq!(runtime.advance(ms(500)), FrameTick { sprite_index: 56, next_frame_in: Some(ms(120)) });
        // Looking after a finished review, the next state still starts at once: the review's
        // start does not count toward it.
        runtime.set_animation("review", ms(1000)).unwrap();
        runtime.look_at(300.0, 5.0, ms(5000)).unwrap();
        assert!(LOOK.contains(&sprite(&mut runtime, 5000)));
        runtime.set_animation("failed", ms(5000)).unwrap();
        assert_eq!(runtime.advance(ms(5100)), FrameTick { sprite_index: 40, next_frame_in: Some(ms(40)) });
    }

    #[test]
    fn a_base_set_while_covered_starts_when_shown() {
        let mut runtime = pet();
        runtime.set_interaction(true, 0, ms(0)).unwrap();
        runtime.set_animation("failed", ms(500)).unwrap();
        assert!(JUMP.contains(&sprite(&mut runtime, 2519)));
        assert_eq!(
            runtime.advance(ms(2520)),
            FrameTick { sprite_index: 40, next_frame_in: Some(ms(140)) },
            "The state set under the jump starts once the jump is done"
        );
        // Shown once, a wave over it does not restart it.
        runtime.play_once("waving", ms(3000)).unwrap();
        assert!(WAVE.contains(&sprite(&mut runtime, 5099)));
        assert_eq!(sprite(&mut runtime, 5100), 41, "2580 ms into failed");

        let mut runtime = pet();
        runtime.play_once("waving", ms(0)).unwrap();
        runtime.set_animation("review", ms(1000)).unwrap();
        assert!(WAVE.contains(&sprite(&mut runtime, 2099)));
        assert_eq!(sprite(&mut runtime, 2100), 64);

        let mut runtime = pet();
        runtime.set_interaction(true, 0, ms(0)).unwrap();
        runtime.set_animation("task-running", ms(500)).unwrap();
        assert!(JUMP.contains(&sprite(&mut runtime, 2519)));
        assert_eq!(
            runtime.advance(ms(2520)),
            FrameTick { sprite_index: 56, next_frame_in: Some(ms(120)) },
            "A task started under the jump runs from its start"
        );
    }

    #[test]
    fn planet_clips_play_as_before() {
        for name in ["ember-planet", "quiet-planet"] {
            let mut runtime = PetRuntime::new(load("planets", name)).unwrap();
            runtime.set_animation("waiting", ms(0)).unwrap();
            assert_eq!(sprite(&mut runtime, 0), 48);
            assert_eq!(sprite(&mut runtime, 150), 49);
            assert_eq!(sprite(&mut runtime, 1010), 48, "The second run");
            assert_eq!(
                runtime.advance(ms(3030)),
                FrameTick { sprite_index: 0, next_frame_in: Some(ms(1680)) },
                "Three runs, then the idle tail"
            );
            runtime.set_animation("spinning", ms(4000)).unwrap();
            for step in 0..20 {
                assert_eq!(
                    runtime.advance(ms(4000 + step * 120)),
                    FrameTick { sprite_index: 72 + step as usize % 16, next_frame_in: Some(ms(120)) }
                );
            }
            runtime.set_animation("spinning", ms(7000)).unwrap();
            assert_eq!(sprite(&mut runtime, 7000), 72, "Setting the same clip restarts it");
            runtime.set_animation("review", ms(8000)).unwrap();
            assert_eq!(sprite(&mut runtime, 8000), 64);
            assert_eq!(sprite(&mut runtime, 11_090), 0);
            runtime.set_animation("running", ms(12_000)).unwrap();
            assert_eq!(sprite(&mut runtime, 12_820), 56, "Running loops");
            runtime.set_animation("idle", ms(20_000)).unwrap();
            assert_eq!(sprite(&mut runtime, 20_000), 0);
        }
    }

    #[test]
    fn one_shot_chains_carry_their_overshoot() {
        let mut pet = load("pets", "chiyan");
        pet.animations.insert("blink".into(), blink());
        let mut runtime = PetRuntime::new(pet).unwrap();
        runtime.set_animation("blink", ms(0)).unwrap();
        assert_eq!(sprite(&mut runtime, 150), 1);
        assert_eq!(
            runtime.advance(ms(250)),
            FrameTick { sprite_index: 56, next_frame_in: Some(ms(70)) },
            "50 ms into the fallback"
        );
        assert_eq!(sprite(&mut runtime, 200 + 820 * 1000 + 130), 57, "Still right after a long sleep");
        // Played once, it ends with itself rather than its fallback.
        runtime.set_animation("idle", ms(1_000_000)).unwrap();
        runtime.play_once("blink", ms(1_000_000)).unwrap();
        assert_eq!(sprite(&mut runtime, 1_000_199), 1);
        assert!(IDLE.contains(&sprite(&mut runtime, 1_000_200)));
    }

    #[test]
    fn once_length_is_the_part_before_the_loop() {
        let pet = load("pets", "chiyan");
        assert_eq!(once_length(&pet.animations["waving"]), ms(2100));
        assert_eq!(once_length(&pet.animations["jumping"]), ms(2520));
        assert_eq!(once_length(&pet.animations["running"]), ms(820), "A loop from its first frame: one cycle");
        assert_eq!(once_length(&blink()), ms(200), "No loop: the whole clip");
    }

    #[test]
    fn invalid_input_is_rejected() {
        let mut runtime = pet();
        assert!(runtime.play_once("no-such-clip", ms(0)).is_err());
        assert!(runtime.set_animation("no-such-clip", ms(0)).is_err());
        assert!(runtime.set_interaction(false, 2, ms(0)).is_err());
        assert!(runtime.look_at(f64::NAN, 0.0, ms(0)).is_err());
    }
}
