use serde::Serialize;
use std::fs::File;
use std::io::Read;
use std::path::Path;

/// One megabyte is enough for embedded artwork before the first MPEG frame.
const HEADER_LIMIT: u64 = 1 << 20;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ProbeResult {
    pub container: String,
    pub codec: Option<String>,
    pub recognized: bool,
    pub error: Option<String>,
}

impl ProbeResult {
    fn recognized(container: &str, codec: Option<String>) -> Self {
        Self {
            container: container.to_string(),
            codec,
            recognized: true,
            error: None,
        }
    }

    fn unknown(error: &str) -> Self {
        Self {
            container: "unknown".to_string(),
            codec: None,
            recognized: false,
            error: Some(error.to_string()),
        }
    }
}

/// Container name from the file signature, or `unknown` when the file
/// cannot be read.
pub fn quick_container(path: &Path) -> String {
    match probe_path(path) {
        Ok(result) => result.container,
        Err(_) => "unknown".to_string(),
    }
}

/// Reads the first megabyte and identifies the container from its signature.
///
/// The extension is never consulted. Codec-level detection is best-effort:
/// ISO BMFF sample entries, Ogg headers, and Matroska/WebM CodecID strings.
pub fn probe_path(path: &Path) -> Result<ProbeResult, String> {
    let file = File::open(path).map_err(|error| format!("cannot open file: {error}"))?;
    let mut header = Vec::with_capacity(HEADER_LIMIT as usize);
    file.take(HEADER_LIMIT)
        .read_to_end(&mut header)
        .map_err(|error| format!("cannot read file: {error}"))?;
    Ok(detect(&header))
}

pub fn detect(data: &[u8]) -> ProbeResult {
    if data.starts_with(b"fLaC") {
        return ProbeResult::recognized("flac", Some("flac".into()));
    }

    if data.starts_with(b"OggS") {
        if find(data, b"OpusHead").is_some() {
            return ProbeResult::recognized("opus", Some("opus".into()));
        }
        if find(data, b"vorbis").is_some() {
            return ProbeResult::recognized("ogg", Some("vorbis".into()));
        }
        if find(data, b"Speex   ").is_some() {
            return ProbeResult::recognized("ogg", Some("speex".into()));
        }
        if find(data, b"FLAC").is_some() {
            return ProbeResult::recognized("ogg", Some("flac".into()));
        }
        return ProbeResult::recognized("ogg", None);
    }

    if data.starts_with(b"RIFF") && data.len() >= 12 && &data[8..12] == b"WAVE" {
        return ProbeResult::recognized("wav", Some("lpcm".into()));
    }

    if data.starts_with(b"FORM") && data.len() >= 12 && (&data[8..12] == b"AIFF" || &data[8..12] == b"AIFC") {
        return ProbeResult::recognized("aiff", Some("lpcm".into()));
    }

    if data.starts_with(b"caff") {
        return ProbeResult::recognized("caf", Some("lpcm".into()));
    }

    if let Some((container, codec)) = detect_iso_bmff(data) {
        return ProbeResult::recognized(&container, codec);
    }

    if data.starts_with(b"MAC ") {
        return ProbeResult::recognized("ape", Some("ape".into()));
    }
    if data.starts_with(b"wvpk") {
        return ProbeResult::recognized("wavpack", Some("wavpack".into()));
    }
    if data.starts_with(b"DSD ") {
        return ProbeResult::recognized("dsf", Some("dsd".into()));
    }
    if data.starts_with(b"FRM8") {
        return ProbeResult::recognized("dff", Some("dsd".into()));
    }

    const ASF_HEADER: [u8; 8] = [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11];
    if data.starts_with(&ASF_HEADER) {
        return ProbeResult::recognized("wma", Some("wma".into()));
    }

    if data.starts_with(&[0x1A, 0x45, 0xDF, 0xA3]) {
        let container = if find(data, b"webm").is_some() {
            "webm"
        } else {
            "mkv"
        };
        return ProbeResult::recognized(container, detect_matroska_codec(data));
    }

    if looks_like_adts(data) {
        return ProbeResult::recognized("aac", Some("aac".into()));
    }

    if looks_like_mp3(data) {
        return ProbeResult::recognized("mp3", Some("mp3".into()));
    }

    ProbeResult::unknown("unrecognized file signature")
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() {
        return Some(0);
    }
    haystack.windows(needle.len()).position(|window| window == needle)
}

/// A single sync word turns up in plenty of binaries, so AAC is only accepted
/// when a short chain of consistent ADTS frames follows.
fn looks_like_adts(data: &[u8]) -> bool {
    let mut index = 0usize;
    let mut frames = 0usize;
    let mut sample_index: Option<u8> = None;

    while index + 7 <= data.len() && frames < 3 {
        let Some(length) = adts_frame_length(&data[index..]) else {
            break;
        };
        if index + length > data.len() {
            break;
        }
        let current = (data[index + 2] >> 2) & 0x0F;
        match sample_index {
            None => sample_index = Some(current),
            Some(expected) if expected != current => return false,
            _ => {}
        }
        frames += 1;
        index += length;
    }

    frames >= 3
}

fn adts_frame_length(frame: &[u8]) -> Option<usize> {
    if frame.len() < 7 || frame[0] != 0xFF || (frame[1] & 0xF6) != 0xF0 {
        return None;
    }
    let sample_index = (frame[2] >> 2) & 0x0F;
    if sample_index >= 13 {
        return None;
    }
    let length = ((frame[3] as usize & 0x03) << 11)
        | ((frame[4] as usize) << 3)
        | ((frame[5] as usize) >> 5);
    if length < 7 {
        None
    } else {
        Some(length)
    }
}

/// Requires consecutive, mutually consistent MPEG audio frames. Scanning for a
/// lone `0xFF 0xEx` pair classifies XZ archives and other binaries as MP3.
fn looks_like_mp3(data: &[u8]) -> bool {
    let mut offset = 0usize;
    if data.starts_with(b"ID3") && data.len() >= 10 {
        let size = ((data[6] & 0x7F) as usize) << 21
            | ((data[7] & 0x7F) as usize) << 14
            | ((data[8] & 0x7F) as usize) << 7
            | (data[9] & 0x7F) as usize;
        offset = 10 + size;
    }

    let mut index = offset;
    let mut frames = 0usize;
    let mut signature: Option<(u8, u8, u8)> = None;

    while index + 4 <= data.len() && frames < 3 {
        let Some((length, version, layer, sample_index)) = mp3_frame(&data[index..]) else {
            index += 1;
            continue;
        };
        if index + length > data.len() {
            break;
        }
        match signature {
            None => signature = Some((version, layer, sample_index)),
            Some(expected) if expected != (version, layer, sample_index) => {
                index += length;
                continue;
            }
            _ => {}
        }
        frames += 1;
        index += length;
    }

    frames >= 3
}

/// Returns the frame length and the parameters that must stay stable between
/// frames: MPEG version, layer and sample-rate index.
fn mp3_frame(frame: &[u8]) -> Option<(usize, u8, u8, u8)> {
    if frame.len() < 4 || frame[0] != 0xFF || (frame[1] & 0xE0) != 0xE0 {
        return None;
    }

    let version = (frame[1] >> 3) & 0x03; // 0 = 2.5, 2 = 2, 3 = 1
    let layer = (frame[1] >> 1) & 0x03; // 1 = III, 2 = II, 3 = I
    if version == 0x01 || layer == 0x00 {
        return None;
    }

    let bitrate_index = (frame[2] >> 4) & 0x0F;
    let sample_index = (frame[2] >> 2) & 0x03;
    let padding = ((frame[2] >> 1) & 0x01) as usize;
    if bitrate_index == 0 || bitrate_index == 0x0F || sample_index == 0x03 {
        return None;
    }

    let bitrate = mp3_bitrate(version, layer, bitrate_index)? as usize * 1000;
    let sample_rate = mp3_sample_rate(version, sample_index)? as usize;

    let length = if layer == 0b11 {
        (12 * bitrate / sample_rate + padding) * 4
    } else {
        let coefficient = if layer == 0b01 && version != 0b11 { 72 } else { 144 };
        coefficient * bitrate / sample_rate + padding
    };
    if length < 24 {
        return None;
    }

    Some((length, version, layer, sample_index))
}

fn mp3_bitrate(version: u8, layer: u8, index: u8) -> Option<u32> {
    const MPEG1: [[u32; 15]; 3] = [
        [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
        [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
        [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
    ];
    const MPEG2: [[u32; 15]; 3] = [
        [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
        [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
        [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
    ];

    let table = if version == 0b11 { &MPEG1 } else { &MPEG2 };
    // Layer bits: 3 = I, 2 = II, 1 = III, while the tables are ordered I, II, III.
    let row = table.get(3 - layer as usize)?;
    row.get(index as usize).copied()
}

fn mp3_sample_rate(version: u8, index: u8) -> Option<u32> {
    match version {
        0b11 => [44_100, 48_000, 32_000].get(index as usize).copied(),
        0b10 => [22_050, 24_000, 16_000].get(index as usize).copied(),
        0b00 => [11_025, 12_000, 8_000].get(index as usize).copied(),
        _ => None,
    }
}

fn detect_matroska_codec(data: &[u8]) -> Option<String> {
    let codecs: [(&[u8], &str); 11] = [
        (b"A_OPUS", "opus"),
        (b"A_VORBIS", "vorbis"),
        (b"A_AAC", "aac"),
        (b"A_FLAC", "flac"),
        (b"A_AC3", "ac-3"),
        (b"A_EAC3", "eac3"),
        (b"A_DTS", "dts"),
        (b"A_MPEG/L3", "mp3"),
        (b"A_TRUEHD", "truehd"),
        (b"A_PCM", "pcm"),
        (b"A_ALAC", "alac"),
    ];
    for (needle, codec) in codecs {
        if find(data, needle).is_some() {
            return Some(codec.to_string());
        }
    }
    None
}

// MARK: - ISO base media file format

fn detect_iso_bmff(data: &[u8]) -> Option<(String, Option<String>)> {
    if data.len() < 12 || &data[4..8] != b"ftyp" {
        return None;
    }

    let brand = ascii(&data[8..12]);
    let mut container = match brand.as_str() {
        "qt  " => "mov",
        "M4A " | "M4B " | "M4P " | "M4R " => "m4a",
        _ => "mp4",
    };

    let Some(moov) = find_box(data, b"moov") else {
        return Some((container.to_string(), None));
    };

    let mut codec = None;
    let mut has_video = false;

    for_each_box(moov, |kind, trak| {
        if kind == b"trak" {
            if let Some(mdia) = find_box(trak, b"mdia") {
                let handler = find_box(mdia, b"hdlr").and_then(|payload| payload.get(8..12));
                match handler {
                    Some(handler) if handler == b"soun" => {
                        if codec.is_none() {
                            codec = find_box(mdia, b"minf")
                                .and_then(|minf| find_box(minf, b"stbl"))
                                .and_then(|stbl| find_box(stbl, b"stsd"))
                                .and_then(|stsd| stsd.get(8..))
                                .and_then(|entries| entries.get(4..8))
                                .map(codec_for_fourcc);
                        }
                    }
                    Some(handler) if handler == b"vide" => {
                        has_video = true;
                    }
                    _ => {}
                }
            }
        }
        true
    });

    if !has_video && (container == "mp4" || container == "mov") {
        container = "m4a";
    }

    Some((container.to_string(), codec))
}

fn find_box<'a>(data: &'a [u8], kind: &[u8; 4]) -> Option<&'a [u8]> {
    let mut found = None;
    for_each_box(data, |child_kind, payload| {
        if child_kind == kind {
            found = Some(payload);
            false
        } else {
            true
        }
    });
    found
}

fn for_each_box<'a, F>(data: &'a [u8], mut visit: F)
where
    F: FnMut(&[u8; 4], &'a [u8]) -> bool,
{
    let mut offset = 0usize;
    while offset + 8 <= data.len() {
        let size32 = u32::from_be_bytes([
            data[offset],
            data[offset + 1],
            data[offset + 2],
            data[offset + 3],
        ]) as usize;

        let kind: [u8; 4] = match data[offset + 4..offset + 8].try_into() {
            Ok(kind) => kind,
            Err(_) => break,
        };

        let (header_size, size) = if size32 == 1 {
            if offset + 16 > data.len() {
                break;
            }
            let large = u64::from_be_bytes([
                data[offset + 8],
                data[offset + 9],
                data[offset + 10],
                data[offset + 11],
                data[offset + 12],
                data[offset + 13],
                data[offset + 14],
                data[offset + 15],
            ]);
            (16usize, usize::try_from(large).unwrap_or(usize::MAX))
        } else if size32 == 0 {
            (8usize, data.len() - offset)
        } else {
            (8usize, size32)
        };

        if size < header_size || offset + size > data.len() {
            break;
        }

        let payload = &data[offset + header_size..offset + size];
        if !visit(&kind, payload) {
            break;
        }
        offset += size;
    }
}

fn codec_for_fourcc(bytes: &[u8]) -> String {
    match bytes {
        b"mp4a" => "aac".to_string(),
        b"alac" => "alac".to_string(),
        b"fLaC" => "flac".to_string(),
        b"Opus" => "opus".to_string(),
        b"ac-3" => "ac-3".to_string(),
        b"ec-3" => "eac3".to_string(),
        b"mp3 " => "mp3".to_string(),
        b"lpcm" => "lpcm".to_string(),
        b"sowt" | b"twos" => "pcm".to_string(),
        other => ascii(other),
    }
}

fn ascii(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|byte| {
            if byte.is_ascii_graphic() || *byte == b' ' {
                *byte as char
            } else {
                '?'
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn boxed(kind: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let size = (8 + payload.len()) as u32;
        let mut out = Vec::with_capacity(size as usize);
        out.extend_from_slice(&size.to_be_bytes());
        out.extend_from_slice(kind);
        out.extend_from_slice(payload);
        out
    }

    fn iso_bmff(handler: &[u8; 4], fourcc: &[u8; 4]) -> Vec<u8> {
        let mut hdlr = vec![0u8; 8];
        hdlr.extend_from_slice(handler);
        let hdlr = boxed(b"hdlr", &hdlr);

        let mut stsd = vec![0u8; 4];
        stsd.extend_from_slice(&1u32.to_be_bytes());
        stsd.extend_from_slice(&8u32.to_be_bytes());
        stsd.extend_from_slice(fourcc);
        let stsd = boxed(b"stsd", &stsd);
        let stbl = boxed(b"stbl", &stsd);
        let minf = boxed(b"minf", &stbl);
        let mdia = boxed(b"mdia", &[hdlr, minf].concat());
        let trak = boxed(b"trak", &mdia);
        let moov = boxed(b"moov", &trak);
        let ftyp = boxed(b"ftyp", b"M4A \0\0\0\0");
        [ftyp, moov].concat()
    }

    #[test]
    fn detects_common_containers() {
        assert_eq!(detect(b"fLaC").container, "flac");
        assert_eq!(detect(b"OggS....OpusHead").container, "opus");
        assert_eq!(detect(b"OggS....vorbis").codec.as_deref(), Some("vorbis"));
        assert_eq!(detect(b"RIFF\0\0\0\0WAVE").container, "wav");
        assert_eq!(detect(b"FORM\0\0\0\0AIFF").container, "aiff");
        assert_eq!(detect(b"caff").container, "caf");
        assert_eq!(detect(b"MAC ").container, "ape");
        assert_eq!(detect(b"wvpk").container, "wavpack");
        assert_eq!(detect(b"DSD ").container, "dsf");
        assert_eq!(detect(b"FRM8").container, "dff");
        assert_eq!(detect(b"\x1A\x45\xDF\xA3....webm....A_OPUS").container, "webm");
        assert_eq!(detect(b"\x1A\x45\xDF\xA3....matroska....A_FLAC").container, "mkv");
    }

    fn mp3_frames(count: usize) -> Vec<u8> {
        // MPEG1 Layer III, 128 kbps, 44.1 kHz, no padding: 417-byte frames.
        let mut data = Vec::new();
        for _ in 0..count {
            let mut frame = vec![0u8; 417];
            frame[0] = 0xFF;
            frame[1] = 0xFB;
            frame[2] = 0x90;
            frame[3] = 0x00;
            data.extend_from_slice(&frame);
        }
        data
    }

    fn adts_frames(count: usize) -> Vec<u8> {
        // AAC-LC 44.1 kHz, 64-byte frames.
        let mut data = Vec::new();
        for _ in 0..count {
            let mut frame = vec![0u8; 64];
            frame[0] = 0xFF;
            frame[1] = 0xF1;
            frame[2] = 0x50;
            frame[3] = 0x80;
            frame[4] = 0x08;
            frame[5] = 0x00;
            frame[6] = 0xFC;
            data.extend_from_slice(&frame);
        }
        data
    }

    #[test]
    fn detects_mp3_and_adts() {
        assert_eq!(detect(&mp3_frames(3)).container, "mp3");
        assert_eq!(detect(&adts_frames(3)).container, "aac");
    }

    #[test]
    fn rejects_stray_sync_words_in_binaries() {
        let mut data = vec![0u8; 64 * 1024];
        data[100] = 0xFF;
        data[101] = 0xFB;
        data[102] = 0x90;
        data[5000] = 0xFF;
        data[5001] = 0xF3;
        assert!(!detect(&data).recognized);
    }

    #[test]
    fn detects_asf() {
        let mut wma = vec![0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11];
        wma.extend_from_slice(&[0u8; 8]);
        assert_eq!(detect(&wma).container, "wma");
    }

    #[test]
    fn detects_m4a_audio_codec() {
        let data = iso_bmff(b"soun", b"mp4a");
        let result = detect(&data);
        assert_eq!(result.container, "m4a");
        assert_eq!(result.codec.as_deref(), Some("aac"));
        assert!(result.recognized);
    }

    #[test]
    fn keeps_mp4_when_video_is_present() {
        let mut hdlr = vec![0u8; 8];
        hdlr.extend_from_slice(b"vide");
        let video = boxed(b"hdlr", &hdlr);
        let video_trak = boxed(b"trak", &boxed(b"mdia", &video));

        let audio = iso_bmff(b"soun", b"mp4a");
        let Some(moov_offset) = find(&audio, b"moov") else {
            panic!("test fixture has no moov");
        };
        // Replace the audio-only moov with one that also contains a video trak.
        let ftyp = boxed(b"ftyp", b"isom\0\0\0\0");
        let audio_moov = &audio[moov_offset - 4..];
        let moov_payload = [video_trak, audio_moov.to_vec()].concat();
        let data = [ftyp, boxed(b"moov", &moov_payload)].concat();
        assert_eq!(detect(&data).container, "mp4");
    }

    #[test]
    fn rejects_unknown_signature() {
        let result = detect(b"not an audio file");
        assert!(!result.recognized);
        assert_eq!(result.container, "unknown");
    }
}
