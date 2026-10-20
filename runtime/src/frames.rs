//! Row-major sprite extraction, independent of the eventual renderer.
use crate::model::Pet;
use anyhow::{Context, Result, ensure};
use image::RgbaImage;

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
        // Copy each frame a row of pixels at a time; going pixel by pixel through a sub-image view
        // takes several times as long for the same bytes.
        let (width, height) = (spec.width as usize, spec.height as usize);
        let sheet_row = width * spec.columns as usize * 4;
        let raw = sheet.as_raw();
        let mut frames = Vec::with_capacity(pet.frame_count());
        for row in 0..spec.rows as usize {
            for column in 0..spec.columns as usize {
                let mut frame = Vec::with_capacity(width * height * 4);
                for y in row * height..(row + 1) * height {
                    let start = y * sheet_row + column * width * 4;
                    frame.extend_from_slice(&raw[start..start + width * 4]);
                }
                frames.push(frame);
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
