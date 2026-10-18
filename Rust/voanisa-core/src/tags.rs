//! Basic tags for containers AVFoundation cannot read.
//!
//! Opus comments come from `opus-pure`'s Ogg layer, Vorbis comments and the
//! other Symphonia-supported formats come from Symphonia's metadata reader,
//! and APE/WavPack read APEv2 tags (with ID3v2 as an APE fallback).
//! Cover art is not handled here: the import pipeline keeps the UI's square
//! placeholder for these files until a picture is chosen by hand.

use std::fs::File;
use std::io::BufReader;
use std::path::Path;

use ape_decoder::ApeDecoder;
use lofty::config::WriteOptions;
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::prelude::{Accessor, ItemKey};
use lofty::tag::Tag;
use serde::Serialize;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::{MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::{MetadataOptions, StandardTag, Visual};

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

impl TrackTags {
    /// True when nothing but the (always computed) duration is present.
    fn is_empty(&self) -> bool {
        self.title.is_none()
            && self.artist.is_none()
            && self.album.is_none()
            && self.album_artist.is_none()
            && self.track_number.is_none()
            && self.disc_number.is_none()
    }
}

/// Reads whatever basic tags a container offers. Unknown or unreadable files
/// return empty tags rather than an error so import can proceed.
pub fn read_tags(path: &Path) -> TrackTags {
    // `lofty` understands ID3v1/v2, MP4 ilst, Vorbis comments, FLAC and APEv2,
    // including the MP3 tags Symphonia 0.6 does not parse at all.
    let mut tags = lofty_tags(path).unwrap_or_default();
    if tags.is_empty() {
        tags = match crate::probe::quick_container(path).as_str() {
            "opus" => opus_tags(path),
            "ape" => ape_tags(path),
            "wavpack" => wavpack_tags(path),
            _ => symphonia_tags(path),
        };
    }
    // `inspect` reads headers only, so a library scan never decodes a whole
    // WavPack or APE file just to learn its duration.
    tags.duration_seconds = crate::decode::inspect(path)
        .map(|info| info.duration_seconds)
        .unwrap_or(0.0);
    tags
}

/// The textual fields the editor writes back into the file.
///
/// `None` and an empty string both mean "remove this field": the editor always
/// sends the complete state, so there is no case where a missing value should
/// keep the old one.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TagWrite {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub track_number: Option<u32>,
    pub disc_number: Option<u32>,
}

/// Writes the metadata editor's values into the audio file itself.
///
/// The library keeps its own copy of the metadata, but a file that is dragged
/// into another player should carry the same information, so edits are mirrored
/// into ID3v2 / MP4 ilst / Vorbis comments / APEv2 through `lofty`.
pub fn write_tags(path: &Path, update: &TagWrite) -> Result<(), String> {
    let mut tagged =
        lofty::read_from_path(path).map_err(|error| format!("{}: {error}", path.display()))?;

    if tagged.primary_tag().is_none() {
        let tag_type = tagged.file_type().primary_tag_type();
        tagged.insert_tag(Tag::new(tag_type));
    }

    let tag = tagged
        .primary_tag_mut()
        .ok_or_else(|| format!("{}: no writable tag", path.display()))?;

    set_text(tag, ItemKey::TrackTitle, update.title.as_deref());
    set_text(tag, ItemKey::TrackArtist, update.artist.as_deref());
    set_text(tag, ItemKey::AlbumTitle, update.album.as_deref());
    set_text(tag, ItemKey::AlbumArtist, update.album_artist.as_deref());

    match update.track_number.filter(|number| *number > 0) {
        Some(number) => tag.set_track(number),
        None => tag.remove_key(&ItemKey::TrackNumber),
    }
    match update.disc_number.filter(|number| *number > 0) {
        Some(number) => tag.set_disk(number),
        None => tag.remove_key(&ItemKey::DiscNumber),
    }

    tagged
        .save_to_path(path, WriteOptions::default())
        .map_err(|error| format!("{}: {error}", path.display()))
}

fn set_text(tag: &mut Tag, key: ItemKey, value: Option<&str>) {
    match value.map(str::trim).filter(|text| !text.is_empty()) {
        Some(text) => {
            tag.insert_text(key, text.to_string());
        }
        None => tag.remove_key(&key),
    }
}

/// An attached picture, exactly as the container stores it.
#[derive(Debug, Clone, PartialEq)]
pub struct Artwork {
    pub mime: String,
    pub data: Vec<u8>,
}

/// Returns the first non-empty attached picture, if the container has one.
///
/// Reading visuals needs a full probe with metadata enabled, so this stays a
/// separate call from `read_tags`: a library scan never pays for artwork it will
/// not show. APEv2 carries cover art as a binary item, which is not parsed yet.
pub fn read_artwork(path: &Path) -> Option<Artwork> {
    if let Some(artwork) = lofty_artwork(path) {
        return Some(artwork);
    }
    let visuals = symphonia_visuals(path)?;
    visuals.into_iter().find_map(|visual| {
        if visual.data.is_empty() {
            return None;
        }
        let mime = visual
            .media_type
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| sniff_image_mime(&visual.data).to_string());
        Some(Artwork {
            mime,
            data: visual.data.to_vec(),
        })
    })
}

/// Writes the artwork to `out` and reports the MIME type that was written.
/// Returns `None` when the container has no picture.
pub fn write_artwork(path: &Path, out: &Path) -> Result<Option<String>, String> {
    let Some(artwork) = read_artwork(path) else {
        return Ok(None);
    };
    std::fs::write(out, &artwork.data)
        .map_err(|error| format!("{}: {error}", out.display()))?;
    Ok(Some(artwork.mime))
}

fn lofty_artwork(path: &Path) -> Option<Artwork> {
    let tagged = lofty::read_from_path(path).ok()?;
    let tag = tagged.primary_tag().or_else(|| tagged.first_tag())?;
    let picture = tag.pictures().iter().find(|picture| !picture.data().is_empty())?;

    let mime = picture
        .mime_type()
        .map(|mime| mime.to_string())
        .unwrap_or_else(|| sniff_image_mime(picture.data()).to_string());

    Some(Artwork {
        mime,
        data: picture.data().to_vec(),
    })
}

fn symphonia_visuals(path: &Path) -> Option<Vec<Visual>> {
    let file = File::open(path).ok()?;
    let stream = MediaSourceStream::new(Box::new(file), MediaSourceStreamOptions::default());

    let mut hint = Hint::new();
    if let Some(extension) = path.extension().and_then(|value| value.to_str()) {
        hint.with_extension(extension);
    }

    let mut format = symphonia::default::get_probe()
        .probe(
            &hint,
            stream,
            FormatOptions::default(),
            MetadataOptions::default(),
        )
        .ok()?;

    let metadata = format.metadata();
    let revision = metadata.current()?;
    Some(revision.media.visuals.clone())
}

fn sniff_image_mime(data: &[u8]) -> &'static str {
    if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        "image/jpeg"
    } else if data.starts_with(b"\x89PNG") {
        "image/png"
    } else if data.starts_with(b"GIF8") {
        "image/gif"
    } else if data.len() > 12 && &data[8..12] == b"WEBP" {
        "image/webp"
    } else {
        "application/octet-stream"
    }
}

fn lofty_tags(path: &Path) -> Option<TrackTags> {
    let tagged = lofty::read_from_path(path).ok()?;
    let tag = tagged.primary_tag().or_else(|| tagged.first_tag())?;

    let mut tags = TrackTags {
        title: clean_opt(tag.title().map(|value| value.to_string())),
        artist: clean_opt(tag.artist().map(|value| value.to_string())),
        album: clean_opt(tag.album().map(|value| value.to_string())),
        album_artist: clean_opt(
            tag.get_string(&ItemKey::AlbumArtist)
                .map(|value| value.to_string()),
        ),
        track_number: tag
            .track()
            .or_else(|| raw_number_lofty(tag, ItemKey::TrackNumber)),
        disc_number: tag
            .disk()
            .or_else(|| raw_number_lofty(tag, ItemKey::DiscNumber)),
        duration_seconds: 0.0,
    };

    if tags.title.is_none() {
        tags.title = clean_opt(
            tag.get_string(&ItemKey::TrackTitle)
                .map(|value| value.to_string()),
        );
    }
    Some(tags)
}

fn raw_number_lofty(tag: &lofty::tag::Tag, key: ItemKey) -> Option<u32> {
    tag.get_string(&key).and_then(parse_number)
}

fn clean_opt(value: Option<String>) -> Option<String> {
    clean_owned(value)
}

fn ape_tags(path: &Path) -> TrackTags {
    let Ok(file) = File::open(path) else {
        return TrackTags::default();
    };
    let Ok(mut decoder) = ApeDecoder::new(BufReader::new(file)) else {
        return TrackTags::default();
    };

    let mut tags = TrackTags::default();
    if let Ok(Some(tag)) = decoder.read_tag() {
        tags = tags_from_apev2(tag.get("Title"), tag.get("Artist"), tag.get("Album"), tag.get("Album Artist").or_else(|| tag.get("AlbumArtist")), tag.get("Track").or_else(|| tag.get("TrackNumber")), tag.get("Disc").or_else(|| tag.get("DiscNumber")));
    }

    // APE files often carry ID3v2 instead, or as well.
    if tags.title.is_none() && tags.artist.is_none() && tags.album.is_none() {
        if let Ok(Some(id3)) = decoder.read_id3v2_tag() {
            tags.title = clean_owned(id3.title());
            tags.artist = clean_owned(id3.artist());
            tags.album = clean_owned(id3.album());
            tags.track_number = id3.track().and_then(|value| parse_number(&value));
        }
    }
    tags
}

fn wavpack_tags(path: &Path) -> TrackTags {
    let Ok(bytes) = std::fs::read(path) else {
        return TrackTags::default();
    };

    let mut found: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    for (key, value) in crate::decode::apev2_items(&bytes) {
        found.insert(key.to_ascii_uppercase(), value);
    }
    let get = |keys: &[&str]| {
        keys.iter()
            .find_map(|key| found.get(*key).cloned())
            .and_then(|value| clean_owned(Some(value)))
    };

    tags_from_apev2(
        get(&["TITLE"]).as_deref(),
        get(&["ARTIST"]).as_deref(),
        get(&["ALBUM"]).as_deref(),
        get(&["ALBUM ARTIST", "ALBUMARTIST"]).as_deref(),
        get(&["TRACK", "TRACKNUMBER"]).as_deref(),
        get(&["DISC", "DISCNUMBER"]).as_deref(),
    )
}

#[allow(clippy::too_many_arguments)]
fn tags_from_apev2(
    title: Option<&str>,
    artist: Option<&str>,
    album: Option<&str>,
    album_artist: Option<&str>,
    track: Option<&str>,
    disc: Option<&str>,
) -> TrackTags {
    TrackTags {
        title: clean(title),
        artist: clean(artist),
        album: clean(album),
        album_artist: clean(album_artist),
        track_number: track.and_then(parse_number),
        disc_number: disc.and_then(parse_number),
        duration_seconds: 0.0,
    }
}

fn clean(value: Option<&str>) -> Option<String> {
    value.and_then(|value| {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    })
}

fn clean_owned(value: Option<String>) -> Option<String> {
    value.and_then(|value| clean(Some(&value)))
}

/// Accepts "3", "3/12" and "03".
fn parse_number(value: &str) -> Option<u32> {
    value
        .split(['/', '-'])
        .next()
        .and_then(|part| part.trim().parse::<u32>().ok())
        .filter(|number| *number > 0)
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
    fn reads_ape_and_wavpack_tags() {
        for name in ["tagged.ape", "tagged.wv"] {
            let tags = read_tags(&fixture(name));
            assert_eq!(tags.title.as_deref(), Some("Voanisa Test Tone"), "{name}");
            assert_eq!(tags.artist.as_deref(), Some("Voanisa"), "{name}");
            assert_eq!(tags.album.as_deref(), Some("Fixtures"), "{name}");
            assert_eq!(tags.track_number, Some(1), "{name}");
            assert!(tags.duration_seconds > 0.2, "{name}");
        }
    }

    #[test]
    fn reads_embedded_artwork() {
        let path = fixture("tagged.m4a");
        if !path.exists() {
            return;
        }
        let artwork = read_artwork(&path).expect("tagged.m4a carries a cover");
        assert!(artwork.data.len() > 100, "picture should not be empty");
        assert!(artwork.mime.starts_with("image/"), "unexpected {}", artwork.mime);

        let out = std::env::temp_dir().join(format!(
            "voanisa-artwork-{}.bin",
            std::process::id()
        ));
        let mime = write_artwork(&path, &out).unwrap();
        assert_eq!(mime.as_deref(), Some(artwork.mime.as_str()));
        assert_eq!(std::fs::read(&out).unwrap(), artwork.data);
        std::fs::remove_file(&out).ok();
    }

    #[test]
    fn files_without_artwork_report_none() {
        let out = std::env::temp_dir().join(format!(
            "voanisa-artwork-none-{}.bin",
            std::process::id()
        ));
        assert_eq!(write_artwork(&fixture("tone.ogg"), &out).unwrap(), None);
        assert!(!out.exists());
    }

    #[test]
    fn reads_id3v2_from_a_bare_mp3() {
        // Symphonia does not parse ID3 at all, so this covers the `lofty` path
        // that replaced AVFoundation for MP3 tags.
        fn text_frame(id: &[u8; 4], text: &str) -> Vec<u8> {
            let mut body = vec![0x03]; // UTF-8
            body.extend_from_slice(text.as_bytes());
            let mut frame = Vec::new();
            frame.extend_from_slice(id);
            frame.extend_from_slice(&(body.len() as u32).to_be_bytes());
            frame.extend_from_slice(&[0, 0]);
            frame.extend_from_slice(&body);
            frame
        }

        let mut frames = Vec::new();
        frames.extend(text_frame(b"TIT2", "ID3 Title"));
        frames.extend(text_frame(b"TPE1", "ID3 Artist"));
        frames.extend(text_frame(b"TALB", "ID3 Album"));
        frames.extend(text_frame(b"TRCK", "7/12"));

        let mut bytes = b"ID3\x03\x00\x00".to_vec();
        let size = frames.len();
        bytes.extend_from_slice(&[
            ((size >> 21) & 0x7f) as u8,
            ((size >> 14) & 0x7f) as u8,
            ((size >> 7) & 0x7f) as u8,
            (size & 0x7f) as u8,
        ]);
        bytes.extend_from_slice(&frames);
        for _ in 0..4 {
            let mut frame = vec![0u8; 417];
            frame[0] = 0xFF;
            frame[1] = 0xFB;
            frame[2] = 0x90;
            bytes.extend_from_slice(&frame);
        }

        let path = std::env::temp_dir().join(format!(
            "voanisa-id3-{}.mp3",
            std::process::id()
        ));
        std::fs::write(&path, &bytes).unwrap();

        let tags = read_tags(&path);
        std::fs::remove_file(&path).ok();

        assert_eq!(tags.title.as_deref(), Some("ID3 Title"));
        assert_eq!(tags.artist.as_deref(), Some("ID3 Artist"));
        assert_eq!(tags.album.as_deref(), Some("ID3 Album"));
        assert_eq!(tags.track_number, Some(7));
    }

    #[test]
    fn writes_tags_back_into_the_file() {
        let source = fixture("tagged.m4a");
        if !source.exists() {
            return;
        }
        let path = std::env::temp_dir().join(format!(
            "voanisa-write-{}.m4a",
            std::process::id()
        ));
        std::fs::copy(&source, &path).unwrap();

        let update = TagWrite {
            title: Some("New Title".into()),
            artist: Some("New Artist".into()),
            album: Some("New Album".into()),
            album_artist: Some("New Album Artist".into()),
            track_number: Some(9),
            disc_number: Some(2),
        };
        write_tags(&path, &update).unwrap();

        let tags = read_tags(&path);
        assert_eq!(tags.title.as_deref(), Some("New Title"));
        assert_eq!(tags.artist.as_deref(), Some("New Artist"));
        assert_eq!(tags.album.as_deref(), Some("New Album"));
        assert_eq!(tags.album_artist.as_deref(), Some("New Album Artist"));
        assert_eq!(tags.track_number, Some(9));
        assert_eq!(tags.disc_number, Some(2));

        // An empty value clears the field: the editor always sends the whole
        // state, so a missing title means "delete the title".
        let cleared = TagWrite {
            title: Some(String::new()),
            ..TagWrite::default()
        };
        write_tags(&path, &cleared).unwrap();
        let tags = read_tags(&path);
        assert_eq!(tags.title, None);
        assert_eq!(tags.album, None);

        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn creates_a_tag_for_an_untagged_mp3() {
        let path = std::env::temp_dir().join(format!(
            "voanisa-write-bare-{}.mp3",
            std::process::id()
        ));
        let mut bytes = Vec::new();
        for _ in 0..4 {
            let mut frame = vec![0u8; 417];
            frame[0] = 0xFF;
            frame[1] = 0xFB;
            frame[2] = 0x90;
            bytes.extend_from_slice(&frame);
        }
        std::fs::write(&path, &bytes).unwrap();

        let update = TagWrite {
            title: Some("Added Later".into()),
            artist: Some("Someone".into()),
            ..TagWrite::default()
        };
        write_tags(&path, &update).unwrap();

        let tags = read_tags(&path);
        std::fs::remove_file(&path).ok();

        assert_eq!(tags.title.as_deref(), Some("Added Later"));
        assert_eq!(tags.artist.as_deref(), Some("Someone"));
    }

    #[test]
    fn missing_file_returns_empty_tags() {
        let tags = read_tags(Path::new("/nonexistent/file.ogg"));
        assert_eq!(tags, TrackTags::default());
    }
}
