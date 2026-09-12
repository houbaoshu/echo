//! Row-major sprite extraction, independent of the eventual renderer.
use crate::model::Pet;
use anyhow::{Context, Result, ensure};
use image::{GenericImageView, RgbaImage};

pub struct SpriteFrames {
    pub width: u32,
    pub height: u32,
    frames: Vec<Vec<u8>>,
}

impl SpriteFrames {
    pub fn load(pet: &Pet) -> Result<Self> {
        // Decode once. Swift copies these straight-alpha RGBA bytes into CGImages.
        let sheet = image::open(&pet.spritesheet_path)
            .with_context(|| format!("decode {}", pet.spritesheet_path.display()))?
            .into_rgba8();
        Self::slice(pet, &sheet)
    }

    fn slice(pet: &Pet, sheet: &RgbaImage) -> Result<Self> {
        let spec = pet.frame;
        ensure!(
            sheet.dimensions() == (spec.width * spec.columns, spec.height * spec.rows),
            "spritesheet dimensions do not match {}×{} grid of {}×{} frames",
            spec.columns,
            spec.rows,
            spec.width,
            spec.height
        );
        let mut frames = Vec::with_capacity(pet.frame_count());
        for row in 0..spec.rows {
            for column in 0..spec.columns {
                frames.push(
                    sheet
                        .view(
                            column * spec.width,
                            row * spec.height,
                            spec.width,
                            spec.height,
                        )
                        .to_image()
                        .into_raw(),
                );
            }
        }
        Ok(Self {
            width: spec.width,
            height: spec.height,
            frames,
        })
    }

    pub fn get(&self, index: usize) -> Option<&[u8]> {
        self.frames.get(index).map(Vec::as_slice)
    }
    pub fn len(&self) -> usize {
        self.frames.len()
    }
    pub fn is_empty(&self) -> bool {
        self.frames.is_empty()
    }
}
