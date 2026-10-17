//! Decoding for containers AVFoundation cannot open on its own.
//!
//! The portable core owns decoding so the same audio pipeline can serve a
//! future Linux or Windows build. Only pure-Rust decoders are used; there is
//! no ffmpeg, no libav and no C toolchain requirement.
//!
//! * Ogg Vorbis, Monkey's Audio and the formats Symphonia demuxes go through
//!   Symphonia.
//! * Ogg Opus goes through `opus-pure`, which carries its own Ogg layer
//!   (RFC 7845) and the pre-skip/end-trim corrections.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use serde::Serialize;
use symphonia::core::codecs::audio::{AudioDecoder as SymphoniaDecoder, AudioDecoderOptions};
use symphonia::core::codecs::CodecParameters;
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo, TrackType};
use symphonia::core::io::{MediaSourceStream, MediaSourceStreamOptions};
use symphonia::core::meta::MetadataOptions;
use symphonia::core::units::Time;

/// What a decoder knows about a stream before playing it.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct DecoderInfo {
    pub container: String,
    pub codec: String,
    pub sample_rate: u32,
    pub channels: usize,
    pub duration_seconds: f64,
}

/// Interleaved `f32` PCM produced from a file, one chunk at a time.
pub struct AudioDecoder {
    backend: Backend,
    info: DecoderInfo,
    /// Samples decoded but not yet handed to the caller (interleaved).
    pending: Vec<f32>,
    pending_offset: usize,
    /// Frames handed to the caller so far, used for position reporting.
    frames_delivered: u64,
    eof: bool,
}

enum Backend {
    Symphonia(SymphoniaSource),
    Opus(Box<OpusSource>),
}

struct SymphoniaSource {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn SymphoniaDecoder>,
    track_id: u32,
    scratch: Vec<f32>,
}

struct OpusSource {
    path: std::path::PathBuf,
    reader: opus_pure::OggOpusReader<File>,
    decoder: opus_pure::OpusDecoder,
    trim: opus_pure::Trim,
    channels: usize,
    block: Vec<f32>,
    /// Samples already discarded by `seek`, in frames.
    skipped: u64,
}

const OPUS_RATE: u32 = 48_000;

impl AudioDecoder {
    pub fn open(path: &Path) -> Result<Self, String> {
        if crate::probe::quick_container(path) == "opus" {
            return Self::open_opus(path);
        }
        Self::open_symphonia(path)
    }

    fn open_opus(path: &Path) -> Result<Self, String> {
        let file = File::open(path).map_err(|error| error.to_string())?;
        let reader = opus_pure::OggOpusReader::new(file).map_err(|error| error.to_string())?;
        let head = reader.head().clone();
        let channels = head.channel_count as usize;
        let decoder = head
            .decoder(OPUS_RATE as i32)
            .map_err(|error| error.to_string())?;
        let trim = opus_pure::Trim::new(&head, OPUS_RATE as i32, channels)
            .map_err(|error| error.to_string())?;

        let duration = ogg_granule_duration(path, OPUS_RATE, u64::from(head.pre_skip), true)
            .unwrap_or(0.0);

        let info = DecoderInfo {
            container: "opus".to_string(),
            codec: "opus".to_string(),
            sample_rate: OPUS_RATE,
            channels,
            duration_seconds: duration,
        };

        Ok(Self {
            backend: Backend::Opus(Box::new(OpusSource {
                path: path.to_path_buf(),
                reader,
                decoder,
                trim,
                channels,
                block: vec![0.0; opus_pure::MAX_PACKET_SAMPLES * channels],
                skipped: 0,
            })),
            info,
            pending: Vec::new(),
            pending_offset: 0,
            frames_delivered: 0,
            eof: false,
        })
    }

    fn open_symphonia(path: &Path) -> Result<Self, String> {
        let file = File::open(path).map_err(|error| error.to_string())?;
        let stream = MediaSourceStream::new(
            Box::new(file),
            MediaSourceStreamOptions::default(),
        );

        let mut hint = Hint::new();
        if let Some(extension) = path.extension().and_then(|value| value.to_str()) {
            hint.with_extension(extension);
        }

        let format = symphonia::default::get_probe()
            .probe(
                &hint,
                stream,
                FormatOptions::default(),
                MetadataOptions::default(),
            )
            .map_err(|error| error.to_string())?;

        let track = format
            .default_track(TrackType::Audio)
            .ok_or_else(|| "no playable track".to_string())?;

        let track_id = track.id;
        let num_frames = track.num_frames;
        let params = match &track.codec_params {
            Some(CodecParameters::Audio(params)) => params.clone(),
            _ => return Err("unsupported codec".to_string()),
        };

        let sample_rate = params
            .sample_rate
            .ok_or_else(|| "unknown sample rate".to_string())?;
        let channels = params
            .channels
            .as_ref()
            .map(|channels| channels.count())
            .ok_or_else(|| "unknown channel layout".to_string())?;

        let decoder = symphonia::default::get_codecs()
            .make_audio_decoder(&params, &AudioDecoderOptions::default())
            .map_err(|error| error.to_string())?;

        let duration = duration_seconds(path, sample_rate, num_frames);
        let probe = crate::probe::probe_path(path).ok();

        let info = DecoderInfo {
            container: crate::probe::quick_container(path),
            codec: probe
                .and_then(|result| result.codec)
                .unwrap_or_else(|| "unknown".to_string()),
            sample_rate,
            channels,
            duration_seconds: duration,
        };

        Ok(Self {
            backend: Backend::Symphonia(SymphoniaSource {
                format,
                decoder,
                track_id,
                scratch: Vec::new(),
            }),
            info,
            pending: Vec::new(),
            pending_offset: 0,
            frames_delivered: 0,
            eof: false,
        })
    }

    pub fn info(&self) -> &DecoderInfo {
        &self.info
    }

    /// Seconds of audio already handed to the caller.
    pub fn position_seconds(&self) -> f64 {
        if self.info.sample_rate == 0 {
            return 0.0;
        }
        self.frames_delivered as f64 / self.info.sample_rate as f64
    }

    /// Fills `out` with interleaved samples. Returns the number of samples
    /// written; `0` means end of stream.
    pub fn read(&mut self, out: &mut [f32]) -> Result<usize, String> {
        let mut written = 0;
        while written < out.len() {
            if self.pending_offset < self.pending.len() {
                let available = self.pending.len() - self.pending_offset;
                let wanted = out.len() - written;
                let count = available.min(wanted);
                out[written..written + count]
                    .copy_from_slice(&self.pending[self.pending_offset..self.pending_offset + count]);
                self.pending_offset += count;
                written += count;
                continue;
            }

            if self.eof {
                break;
            }

            self.pending.clear();
            self.pending_offset = 0;
            let chunk = match &mut self.backend {
                Backend::Symphonia(source) => source.next_chunk()?,
                Backend::Opus(source) => source.next_chunk()?,
            };
            if chunk.is_empty() {
                self.eof = true;
                break;
            }
            self.pending = chunk;
        }

        if self.info.channels > 0 {
            self.frames_delivered += (written / self.info.channels) as u64;
        }
        Ok(written)
    }

    /// Repositions the stream. Opus is re-read from the start because its Ogg
    /// reader is forward-only; that costs a fast decode of the skipped part.
    pub fn seek(&mut self, seconds: f64) -> Result<(), String> {
        self.pending.clear();
        self.pending_offset = 0;
        self.eof = false;
        self.frames_delivered = 0;

        let start_frames = match &mut self.backend {
            Backend::Symphonia(source) => {
                let target = seconds.max(0.0);
                let time = Time::try_from_secs_f64(target)
                    .ok_or_else(|| "invalid seek time".to_string())?;
                source
                    .format
                    .seek(
                        SeekMode::Accurate,
                        SeekTo::Time {
                            time,
                            track_id: Some(source.track_id),
                        },
                    )
                    .map_err(|error| error.to_string())?;
                source.decoder.reset();
                source.scratch.clear();
                (target * f64::from(self.info.sample_rate)) as u64
            }
            Backend::Opus(source) => {
                source.restart()?;
                if seconds > 0.0 {
                    source.skip_to(seconds)?
                } else {
                    0
                }
            }
        };
        self.frames_delivered = start_frames;
        Ok(())
    }
}

impl SymphoniaSource {
    fn next_chunk(&mut self) -> Result<Vec<f32>, String> {
        loop {
            let packet = match self.format.next_packet() {
                Ok(Some(packet)) => packet,
                Ok(None) => return Ok(Vec::new()),
                Err(SymphoniaError::ResetRequired) => {
                    return Err("decoder reset required".to_string())
                }
                Err(error) => return Err(error.to_string()),
            };

            if packet.track_id != self.track_id {
                continue;
            }

            let decoded = match self.decoder.decode(&packet) {
                Ok(decoded) => decoded,
                Err(SymphoniaError::DecodeError(_)) => continue,
                Err(error) => return Err(error.to_string()),
            };

            if decoded.frames() == 0 {
                continue;
            }

            self.scratch.clear();
            decoded.copy_to_vec_interleaved::<f32>(&mut self.scratch);
            if self.scratch.is_empty() {
                continue;
            }
            return Ok(std::mem::take(&mut self.scratch));
        }
    }
}

impl OpusSource {
    fn restart(&mut self) -> Result<(), String> {
        let file = File::open(&self.path).map_err(|error| error.to_string())?;
        let mut reader =
            opus_pure::OggOpusReader::new(file).map_err(|error| error.to_string())?;
        let head = reader.head().clone();
        let decoder = head
            .decoder(OPUS_RATE as i32)
            .map_err(|error| error.to_string())?;
        let trim =
            opus_pure::Trim::new(&head, OPUS_RATE as i32, self.channels).map_err(|error| error.to_string())?;
        // The rebuilt reader starts at the first audio packet; skipping happens
        // through `skip_to` so `trim` still counts from the stream start.
        reader.rewind().ok();
        self.reader = reader;
        self.decoder = decoder;
        self.trim = trim;
        self.skipped = 0;
        Ok(())
    }

    fn next_chunk(&mut self) -> Result<Vec<f32>, String> {
        loop {
            let packet = match self
                .reader
                .read_packet()
                .map_err(|error| error.to_string())?
            {
                Some(packet) => packet,
                None => return Ok(Vec::new()),
            };

            let count = self
                .decoder
                .decode(&packet.data, opus_pure::MAX_PACKET_SAMPLES, &mut self.block)
                .map_err(|error| error.to_string())?;

            let kept = self
                .trim
                .keep(&packet, &self.block[..count * self.channels]);
            if !kept.is_empty() {
                return Ok(kept.to_vec());
            }
        }
    }

    fn skip_to(&mut self, seconds: f64) -> Result<u64, String> {
        let target = (seconds * f64::from(OPUS_RATE)).round().max(0.0) as u64;
        let mut frames = 0u64;
        while frames < target {
            let kept = self.next_chunk()?;
            if kept.is_empty() {
                break;
            }
            frames += (kept.len() / self.channels) as u64;
        }
        self.skipped = frames.min(target);
        Ok(self.skipped)
    }
}

/// Reads the granule position of the last Ogg page.
///
/// Ogg stores the total number of samples in the final page header, so the
/// duration is available without decoding the file.
fn ogg_granule_duration(
    path: &Path,
    sample_rate: u32,
    pre_skip: u64,
    _opus: bool,
) -> Option<f64> {
    if sample_rate == 0 {
        return None;
    }
    let granule = ogg_last_granule(path)?;
    let samples = granule.saturating_sub(pre_skip);
    Some(samples as f64 / f64::from(sample_rate))
}

fn ogg_last_granule(path: &Path) -> Option<u64> {
    const TAIL: u64 = 64 * 1024;
    let mut file = File::open(path).ok()?;
    let length = file.metadata().ok()?.len();
    let start = length.saturating_sub(TAIL);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut tail = Vec::new();
    file.read_to_end(&mut tail).ok()?;

    let mut granule = None;
    let mut offset = 0usize;
    while offset + 14 <= tail.len() {
        if &tail[offset..offset + 4] == b"OggS" {
            let value = i64::from_le_bytes([
                tail[offset + 6],
                tail[offset + 7],
                tail[offset + 8],
                tail[offset + 9],
                tail[offset + 10],
                tail[offset + 11],
                tail[offset + 12],
                tail[offset + 13],
            ]);
            if value >= 0 {
                granule = Some(value as u64);
            }
        }
        offset += 1;
    }
    granule
}

fn duration_seconds(path: &Path, sample_rate: u32, n_frames: Option<u64>) -> f64 {
    if let Some(frames) = n_frames {
        if frames > 0 && sample_rate > 0 {
            return frames as f64 / f64::from(sample_rate);
        }
    }
    ogg_granule_duration(path, sample_rate, 0, false).unwrap_or(0.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> std::path::PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../VoanisaTests/Fixtures/audio")
            .join(name)
    }

    fn decode_all(decoder: &mut AudioDecoder) -> Vec<f32> {
        let mut out = vec![0.0f32; 4096 * decoder.info().channels];
        let mut total = Vec::new();
        loop {
            let count = decoder.read(&mut out).expect("read");
            if count == 0 {
                return total;
            }
            total.extend_from_slice(&out[..count]);
        }
    }

    #[test]
    fn decodes_ogg_vorbis() {
        let mut decoder = AudioDecoder::open(&fixture("tone.ogg")).expect("open ogg");
        assert_eq!(decoder.info().container, "ogg");
        assert_eq!(decoder.info().channels, 2);
        assert!((decoder.info().duration_seconds - 0.3).abs() < 0.05);
        let pcm = decode_all(&mut decoder);
        let frames = pcm.len() / 2;
        assert!(frames > 5_000, "decoded {frames} frames");
    }

    #[test]
    fn decodes_ogg_opus() {
        let mut decoder = AudioDecoder::open(&fixture("tone.opus")).expect("open opus");
        assert_eq!(decoder.info().container, "opus");
        assert_eq!(decoder.info().sample_rate, 48_000);
        assert!((decoder.info().duration_seconds - 0.3).abs() < 0.05);
        let pcm = decode_all(&mut decoder);
        let frames = pcm.len() / 2;
        assert!(frames > 10_000, "decoded {frames} frames");
    }

    #[test]
    fn seeks_in_ogg_vorbis() {
        let mut decoder = AudioDecoder::open(&fixture("tone.ogg")).expect("open ogg");
        let all = decode_all(&mut decoder);
        decoder.seek(0.15).expect("seek");
        let tail = decode_all(&mut decoder);
        assert!(!tail.is_empty());
        assert!(tail.len() < all.len(), "seek should skip the head");
        assert!(
            (decoder.position_seconds() - 0.3).abs() < 0.05,
            "position {}",
            decoder.position_seconds()
        );
    }
}
