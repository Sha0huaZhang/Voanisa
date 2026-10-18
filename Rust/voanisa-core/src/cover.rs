//! Cover rendering.
//!
//! Imported artwork has to become a square JPEG before the library can show it.
//! Doing that in the core keeps the pipeline free of CoreGraphics and gives the
//! same result on every platform; Swift keeps its CoreGraphics path only for
//! formats `image` cannot decode (notably HEIC).

use std::io::BufWriter;
use std::path::Path;

use image::imageops::FilterType;
use image::{DynamicImage, ImageReader};

/// What the renderer produced, mostly for logging and tests.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
pub struct CoverResult {
    /// Width of the decoded source, after EXIF orientation.
    pub source_width: u32,
    pub source_height: u32,
    /// Size of the written square.
    pub side: u32,
}

/// Decodes `source`, applies EXIF orientation, crops the largest centred
/// square and writes it as a JPEG of `side` pixels to `out`.
pub fn write_square_cover(
    source: &Path,
    out: &Path,
    side: u32,
    quality: u8,
) -> Result<CoverResult, String> {
    let side = side.clamp(1, 8192);
    let quality = quality.clamp(1, 100);

    let bytes = std::fs::read(source).map_err(|error| format!("{}: {error}", source.display()))?;
    let orientation = exif_orientation(&bytes);
    let decoded = ImageReader::new(std::io::Cursor::new(&bytes))
        .with_guessed_format()
        .map_err(|error| format!("{}: {error}", source.display()))?
        .decode()
        .map_err(|error| format!("{}: {error}", source.display()))?;

    let oriented = apply_orientation(decoded, orientation);
    let (source_width, source_height) = (oriented.width(), oriented.height());
    if source_width == 0 || source_height == 0 {
        return Err(format!("{}: empty image", source.display()));
    }

    let edge = source_width.min(source_height);
    let square = oriented.crop_imm(
        (source_width - edge) / 2,
        (source_height - edge) / 2,
        edge,
        edge,
    );
    let resized = square.resize_exact(side, side, FilterType::Lanczos3);

    let file = std::fs::File::create(out).map_err(|error| format!("{}: {error}", out.display()))?;
    let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(
        BufWriter::new(file),
        quality,
    );
    encoder
        .encode_image(&resized)
        .map_err(|error| format!("{}: {error}", out.display()))?;

    Ok(CoverResult {
        source_width,
        source_height,
        side,
    })
}

const ORIENTATION_TAG: u16 = 0x0112;

/// Reads the EXIF orientation tag (0x0112) from a JPEG's APP1 segment.
///
/// `image` decodes the pixels but ignores orientation, so a phone photo taken
/// sideways would be cropped along the wrong axis without this.
fn exif_orientation(bytes: &[u8]) -> u32 {
    if bytes.len() < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8 {
        return 1;
    }

    let mut offset = 2usize;
    while offset + 4 <= bytes.len() {
        if bytes[offset] != 0xFF {
            offset += 1;
            continue;
        }
        let marker = bytes[offset + 1];
        let length = u16::from_be_bytes([bytes[offset + 2], bytes[offset + 3]]) as usize;
        if marker == 0xE1 && length >= 8 {
            let start = offset + 4;
            let end = (offset + 2 + length).min(bytes.len());
            if end > start + 6 && &bytes[start..start + 6] == b"Exif\0\0" {
                return tiff_orientation(&bytes[start + 6..end]);
            }
        }
        if marker == 0xDA {
            break;
        }
        offset += 2 + length;
    }
    1
}

fn tiff_orientation(tiff: &[u8]) -> u32 {
    if tiff.len() < 8 {
        return 1;
    }
    let little_endian = match &tiff[0..2] {
        b"II" => true,
        b"MM" => false,
        _ => return 1,
    };

    let read_u16 = |at: usize| -> Option<u16> {
        let slice = tiff.get(at..at + 2)?;
        Some(if little_endian {
            u16::from_le_bytes([slice[0], slice[1]])
        } else {
            u16::from_be_bytes([slice[0], slice[1]])
        })
    };
    let read_u32 = |at: usize| -> Option<u32> {
        let slice = tiff.get(at..at + 4)?;
        Some(if little_endian {
            u32::from_le_bytes([slice[0], slice[1], slice[2], slice[3]])
        } else {
            u32::from_be_bytes([slice[0], slice[1], slice[2], slice[3]])
        })
    };

    let Some(ifd_offset) = read_u32(4) else {
        return 1;
    };
    // The offset is measured from the start of the TIFF header, and the header
    // itself is 8 bytes, so the IFD usually sits at byte 8.
    let ifd = ifd_offset as usize;
    let Some(entry_count) = read_u16(ifd) else {
        return 1;
    };

    for index in 0..entry_count as usize {
        let entry = ifd + 2 + index * 12;
        let Some(tag) = read_u16(entry) else { break };
        if tag == ORIENTATION_TAG {
            // Value fits in the offset field for SHORT.
            return read_u16(entry + 8).unwrap_or(1).clamp(1, 8) as u32;
        }
    }
    1
}

/// Applies the EXIF orientation to the decoded pixels.
fn apply_orientation(image: DynamicImage, orientation: u32) -> DynamicImage {
    match orientation {
        2 => image.fliph(),
        3 => image.rotate180(),
        4 => image.flipv(),
        5 => image.rotate90().fliph(),
        6 => image.rotate90(),
        7 => image.rotate270().fliph(),
        8 => image.rotate270(),
        _ => image,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{ImageFormat, Rgb, RgbImage};

    fn temp(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!("voanisa-cover-{}-{name}", std::process::id()))
    }

    fn write_test_png(path: &Path, width: u32, height: u32) {
        let mut image = RgbImage::new(width, height);
        for (x, y, pixel) in image.enumerate_pixels_mut() {
            *pixel = Rgb([(x % 256) as u8, (y % 256) as u8, 120]);
        }
        image.save_with_format(path, ImageFormat::Png).unwrap();
    }

    #[test]
    fn crops_the_centre_square_and_writes_a_jpeg() {
        let source = temp("wide.png");
        let out = temp("wide.jpg");
        write_test_png(&source, 400, 200);

        let result = write_square_cover(&source, &out, 256, 85).unwrap();
        assert_eq!(result.source_width, 400);
        assert_eq!(result.source_height, 200);
        assert_eq!(result.side, 256);

        let written = image::open(&out).unwrap();
        assert_eq!((written.width(), written.height()), (256, 256));

        std::fs::remove_file(&source).ok();
        std::fs::remove_file(&out).ok();
    }

    #[test]
    fn clamps_absurd_sizes() {
        let source = temp("clamp.png");
        let out = temp("clamp.jpg");
        write_test_png(&source, 32, 32);

        let result = write_square_cover(&source, &out, 0, 250).unwrap();
        assert_eq!(result.side, 1);

        std::fs::remove_file(&source).ok();
        std::fs::remove_file(&out).ok();
    }

    #[test]
    fn reports_undecodable_files() {
        let source = temp("junk.png");
        let out = temp("junk.jpg");
        std::fs::write(&source, b"not an image").unwrap();

        assert!(write_square_cover(&source, &out, 64, 80).is_err());

        std::fs::remove_file(&source).ok();
        std::fs::remove_file(&out).ok();
    }

    #[test]
    fn reads_jpeg_exif_orientation() {
        // Little-endian TIFF header with one IFD entry: orientation = 6.
        let mut app1 = Vec::new();
        app1.extend_from_slice(b"Exif\0\0");
        app1.extend_from_slice(b"II*\0");
        app1.extend_from_slice(&8u32.to_le_bytes());
        app1.extend_from_slice(&1u16.to_le_bytes());
        app1.extend_from_slice(&0x0112u16.to_le_bytes());
        app1.extend_from_slice(&3u16.to_le_bytes()); // SHORT
        app1.extend_from_slice(&1u32.to_le_bytes());
        app1.extend_from_slice(&6u16.to_le_bytes());
        app1.extend_from_slice(&0u16.to_le_bytes());
        app1.extend_from_slice(&0u32.to_le_bytes());

        let mut jpeg = vec![0xFF, 0xD8, 0xFF, 0xE1];
        jpeg.extend_from_slice(&((app1.len() + 2) as u16).to_be_bytes());
        jpeg.extend_from_slice(&app1);
        jpeg.extend_from_slice(&[0xFF, 0xDA, 0x00, 0x02]);

        assert_eq!(exif_orientation(&jpeg), 6);
        assert_eq!(exif_orientation(b"not a jpeg"), 1);
    }
}
