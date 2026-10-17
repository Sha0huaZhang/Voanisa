//! Basic tags for containers AVFoundation cannot read.
//!
//! Opus comments come from `opus-pure`'s Ogg layer, Vorbis comments and the
//! other Symphonia-supported formats come from Symphonia's metadata reader.
//! Cover art is not handled here: the import pipeline keeps the UI's square
//! placeholder for these files until a picture is chosen by hand.

use std::fs::File;
use std::path::Path;

use serde::Serialize;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::{MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::{MetadataOptions, StandardTag};

#[derive(Debug, Clone, Default, Serialize, PartialEq)]
pub struct TrackTags {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track_number: Option<u32>,
    pub disc_number: Option<u32>,
    pub duration_seconds: f64,
}

/// Reads whatever basic tags a container offers. Unknown or unreadable files
/// return empty tags rather than an error so import can proceed.
pub fn read_tags(path: &Path) -> TrackTags {
    let container = crate::probe::quick_container(path);
    let mut tags = if container == "opus" {
        opus_tags(path)
    } else {
        symphonia_tags(path)
    };
    tags.duration_seconds = crate::decode::AudioDecoder::open(path)
        .map(|decoder| decoder.info().duration_seconds)
        .unwrap_or(0.0);
    tags
}

fn opus_tags(path: &Path) -> TrackTags {
    let Ok(file) = File::open(path) else {
        return TrackTags::default();
    };
    let Ok(reader) = opus_pure::OggOpusReader::new(file) else {
        return TrackTags::default();
    };

    let mut tags = TrackTags::default();
    for comment in &reader.tags().comments {
        let Some((key, value)) = comment.split_once('=') else {
            continue;
        };
        let value = value.trim();
        if value.is_empty() {
            continue;
        }
        match key.to_ascii_uppercase().as_str() {
            "TITLE" => tags.title = Some(value.to_string()),
            "ARTIST" => tags.artist = Some(value.to_string()),
            "ALBUM" => tags.album = Some(value.to_string()),
            "ALBUMARTIST" | "ALBUM ARTIST" => tags.album_artist = Some(value.to_string()),
            "TRACKNUMBER" => tags.track_number = value.parse().ok(),
            "DISCNUMBER" => tags.disc_number = value.parse().ok(),
            _ => {}
        }
    }
    tags
}

fn symphonia_tags(path: &Path) -> TrackTags {
    let mut tags = TrackTags::default();
    let Ok(file) = File::open(path) else {
        return tags;
    };
    let stream = MediaSourceStream::new(Box::new(file), MediaSourceStreamOptions::default());

    let mut hint = Hint::new();
    if let Some(extension) = path.extension().and_then(|value| value.to_str()) {
        hint.with_extension(extension);
    }

    let Ok(mut format) = symphonia::default::get_probe().probe(
        &hint,
        stream,
        FormatOptions::default(),
        MetadataOptions::default(),
    ) else {
        return tags;
    };

    let metadata = format.metadata();
    let Some(revision) = metadata.current() else {
        return tags;
    };

    for tag in &revision.media.tags {
        let Some(std) = &tag.std else { continue };
        match std {
            StandardTag::TrackTitle(value) => tags.title = non_empty(value),
            StandardTag::Artist(value) => tags.artist = non_empty(value),
            StandardTag::Album(value) => tags.album = non_empty(value),
            StandardTag::AlbumArtist(value) => tags.album_artist = non_empty(value),
            StandardTag::TrackNumber(number) => {
                tags.track_number = u32::try_from(*number).ok().filter(|value| *value > 0)
            }
            StandardTag::DiscNumber(number) => {
                tags.disc_number = u32::try_from(*number).ok().filter(|value| *value > 0)
            }
            _ => {}
        }
    }

    // Some taggers write TRACKNUMBER as "3/12"; fall back to the raw value when
    // the standard mapping did not produce a number.
    if tags.title.is_none() {
        tags.title = raw_text(&revision.media.tags, "TITLE");
    }
    if tags.artist.is_none() {
        tags.artist = raw_text(&revision.media.tags, "ARTIST");
    }
    if tags.album.is_none() {
        tags.album = raw_text(&revision.media.tags, "ALBUM");
    }
    if tags.album_artist.is_none() {
        tags.album_artist = raw_text(&revision.media.tags, "ALBUMARTIST");
    }
    if tags.track_number.is_none() {
        tags.track_number = raw_number(&revision.media.tags, "TRACKNUMBER");
    }
    if tags.disc_number.is_none() {
        tags.disc_number = raw_number(&revision.media.tags, "DISCNUMBER");
    }
    tags
}

fn non_empty(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn raw_text(tags: &[symphonia::core::meta::Tag], key: &str) -> Option<String> {
    tags.iter().find_map(|tag| {
        if tag.raw.key.to_ascii_uppercase() != key {
            return None;
        }
        non_empty(&tag.raw.value.to_string())
    })
}

fn raw_number(tags: &[symphonia::core::meta::Tag], key: &str) -> Option<u32> {
    tags.iter().find_map(|tag| {
        let name = tag.raw.key.to_ascii_uppercase();
        if name != key {
            return None;
        }
        let value = tag.raw.value.to_string();
        value
            .split(['/', '-'])
            .next()
            .and_then(|part| part.trim().parse::<u32>().ok())
            .filter(|value| *value > 0)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> std::path::PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../VoanisaTests/Fixtures/audio")
            .join(name)
    }

    #[test]
    fn reads_opus_comments() {
        let path = fixture("tagged.opus");
        if !path.exists() {
            return;
        }
        let tags = read_tags(&path);
        assert_eq!(tags.title.as_deref(), Some("Voanisa Test Tone"));
    }

    #[test]
    fn reads_vorbis_comments() {
        let path = fixture("tagged.ogg");
        if !path.exists() {
            return;
        }
        let tags = read_tags(&path);
        assert_eq!(tags.artist.as_deref(), Some("Voanisa"));
        assert_eq!(tags.track_number, Some(1));
    }

    #[test]
    fn missing_file_returns_empty_tags() {
        let tags = read_tags(Path::new("/nonexistent/file.ogg"));
        assert_eq!(tags, TrackTags::default());
    }
}
