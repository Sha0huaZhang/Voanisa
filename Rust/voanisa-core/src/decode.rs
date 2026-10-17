//! Decoding for containers AVFoundation cannot open on its own.
//!
//! The portable core owns decoding so the same audio pipeline can serve a
//! future Linux or Windows build. Only pure-Rust decoders are used; there is
//! no ffmpeg, no libav and no C toolchain requirement.
//!
//! * Ogg Vorbis and the other formats Symphonia demuxes go through Symphonia.
//! * Ogg Opus goes through `opus-pure`, which carries its own Ogg layer
//!   (RFC 7845) and the pre-skip/end-trim corrections.
//! * WavPack goes through `wavicle`, which decodes the whole lossless stream.
//! * Monkey's Audio (APE) goes through `ape-decoder`, frame by frame.

use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use ape_decoder::ApeDecoder;
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
    WavPack(Box<WavPackSource>),
    Ape(Box<ApeSource>),
}

struct SymphoniaSource {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn SymphoniaDecoder>,
    track_id: u32,
    sample_rate: u32,
    scratch: Vec<f32>,
}

struct OpusSource {
    path: PathBuf,
    reader: opus_pure::OggOpusReader<File>,
    decoder: opus_pure::OpusDecoder,
    trim: opus_pure::Trim,
    channels: usize,
    block: Vec<f32>,
}

struct WavPackSource {
    bytes: Vec<u8>,
    /// Decoded on the first read so probing a whole library stays cheap.
    samples: Option<Vec<i32>>,
    channels: usize,
    bits: u32,
    is_float: bool,
    cursor_frames: usize,
    total_frames: usize,
    sample_rate: u32,
}

struct ApeSource {
    decoder: ApeDecoder<BufReader<File>>,
    channels: usize,
    bits: u32,
    total_frames: u32,
    next_frame: u32,
    /// Frames to drop from the front of the next decoded frame after a seek.
    skip_frames: usize,
}

const OPUS_RATE: u32 = 48_000;

/// WavPack's decoder produces the whole file at once, so a very long file would
/// cost a lot of memory. 100M samples is roughly 19 minutes of stereo 44.1 kHz.
const MAX_WAVPACK_SAMPLES: u64 = 100_000_000;

impl AudioDecoder {
    pub fn open(path: &Path) -> Result<Self, String> {
        match crate::probe::quick_container(path).as_str() {
            "opus" => Self::open_opus(path),
            "wavpack" => Self::open_wavpack(path),
            "ape" => Self::open_ape(path),
            _ => Self::open_symphonia(path),
        }
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
                out[written..written + count].copy_from_slice(
                    &self.pending[self.pending_offset..self.pending_offset + count],
                );
                self.pending_offset += count;
                written += count;
                continue;
            }

            if self.eof {
                break;
            }

            self.pending.clear();
            self.pending_offset = 0;
            let frames = out.len() / self.info.channels.max(1);
            let chunk = self.backend.next_chunk(frames.max(1))?;
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

    /// Repositions the stream. Opus and WavPack restart from the beginning
    /// internally; that costs a fast decode of the skipped part.
    pub fn seek(&mut self, seconds: f64) -> Result<(), String> {
        self.pending.clear();
        self.pending_offset = 0;
        self.eof = false;
        let start = self.backend.seek(seconds.max(0.0))?;
        self.frames_delivered = start;
        Ok(())
    }

    // MARK: - Backends

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

        let duration =
            ogg_granule_duration(path, OPUS_RATE, u64::from(head.pre_skip), true).unwrap_or(0.0);

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
            })),
            info,
            pending: Vec::new(),
            pending_offset: 0,
            frames_delivered: 0,
            eof: false,
        })
    }

    fn open_wavpack(path: &Path) -> Result<Self, String> {
        let mut bytes = std::fs::read(path).map_err(|error| error.to_string())?;
        trim_apev2(&mut bytes);

        let source = read_wavpack_info(&bytes)?;
        if !source.lossless {
            return Err("hybrid WavPack files are not supported".to_string());
        }

        let frames = source
            .total_samples
            .unwrap_or_else(|| wavpack_total_frames(&bytes));
        if frames.saturating_mul(u64::from(source.channels)) > MAX_WAVPACK_SAMPLES {
            return Err("WavPack file is too long for the in-memory decoder".to_string());
        }

        let info = DecoderInfo {
            container: "wavpack".to_string(),
            codec: if source.is_float {
                "pcm_f32".to_string()
            } else {
                "pcm_s16".to_string()
            },
            sample_rate: source.sample_rate,
            channels: source.channels as usize,
            duration_seconds: if source.sample_rate > 0 {
                frames as f64 / f64::from(source.sample_rate)
            } else {
                0.0
            },
        };

        Ok(Self {
            backend: Backend::WavPack(Box::new(WavPackSource {
                bytes,
                samples: None,
                channels: info.channels,
                bits: source.bits_per_sample,
                is_float: source.is_float,
                cursor_frames: 0,
                total_frames: frames as usize,
                sample_rate: info.sample_rate,
            })),
            info,
            pending: Vec::new(),
            pending_offset: 0,
            frames_delivered: 0,
            eof: false,
        })
    }

    fn open_ape(path: &Path) -> Result<Self, String> {
        let file = File::open(path).map_err(|error| error.to_string())?;
        let decoder = ApeDecoder::new(BufReader::new(file)).map_err(|error| error.to_string())?;
        let stream = decoder.info().clone();
        let total_frames = decoder.total_frames();

        let info = DecoderInfo {
            container: "ape".to_string(),
            codec: pcm_codec_name(stream.bits_per_sample),
            sample_rate: stream.sample_rate,
            channels: stream.channels as usize,
            duration_seconds: if stream.sample_rate > 0 {
                stream.total_samples as f64 / f64::from(stream.sample_rate)
            } else {
                0.0
            },
        };

        Ok(Self {
            backend: Backend::Ape(Box::new(ApeSource {
                decoder,
                channels: info.channels,
                bits: u32::from(stream.bits_per_sample),
                total_frames,
                next_frame: 0,
                skip_frames: 0,
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
        let stream =
            MediaSourceStream::new(Box::new(file), MediaSourceStreamOptions::default());

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
                sample_rate,
                scratch: Vec::new(),
            }),
            info,
            pending: Vec::new(),
            pending_offset: 0,
            frames_delivered: 0,
            eof: false,
        })
    }
}

impl Backend {
    /// Returns the next interleaved chunk. `frames` is a hint for the maximum
    /// number of frames worth decoding at once.
    fn next_chunk(&mut self, frames: usize) -> Result<Vec<f32>, String> {
        match self {
            Backend::Symphonia(source) => source.next_chunk(),
            Backend::Opus(source) => source.next_chunk(),
            Backend::WavPack(source) => source.next_chunk(frames),
            Backend::Ape(source) => source.next_chunk(),
        }
    }

    /// Returns the absolute frame the stream now starts at.
    fn seek(&mut self, seconds: f64) -> Result<u64, String> {
        match self {
            Backend::Symphonia(source) => {
                let time = Time::try_from_secs_f64(seconds)
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
                Ok((seconds * f64::from(source.sample_rate)).round() as u64)
            }
            Backend::Opus(source) => {
                source.restart()?;
                source.skip_to(seconds)
            }
            Backend::WavPack(source) => source.seek(seconds),
            Backend::Ape(source) => source.seek(seconds),
        }
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
        let trim = opus_pure::Trim::new(&head, OPUS_RATE as i32, self.channels)
            .map_err(|error| error.to_string())?;
        // The rebuilt reader starts at the first audio packet; skipping happens
        // through `skip_to` so `trim` still counts from the stream start.
        reader.rewind().ok();
        self.reader = reader;
        self.decoder = decoder;
        self.trim = trim;
        Ok(())
    }

    fn next_chunk(&mut self) -> Result<Vec<f32>, String> {
        loop {
            let packet = match self.reader.read_packet().map_err(|error| error.to_string())? {
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
        Ok(frames.min(target))
    }
}

impl WavPackSource {
    fn ensure_decoded(&mut self) -> Result<(), String> {
        if self.samples.is_some() {
            return Ok(());
        }
        let decoded = wavicle::decode_stream(&self.bytes).map_err(|error| error.to_string())?;
        self.samples = Some(decoded.samples);
        // The compressed bytes are no longer needed once PCM is in memory.
        self.bytes = Vec::new();
        Ok(())
    }

    fn next_chunk(&mut self, frames: usize) -> Result<Vec<f32>, String> {
        self.ensure_decoded()?;
        let Some(samples) = self.samples.as_ref() else {
            return Ok(Vec::new());
        };

        let start = self.cursor_frames * self.channels;
        if start >= samples.len() {
            return Ok(Vec::new());
        }
        let end = (start + frames * self.channels).min(samples.len());
        self.cursor_frames = end / self.channels;

        Ok(samples[start..end]
            .iter()
            .map(|sample| wavpack_sample_to_f32(*sample, self.bits, self.is_float))
            .collect())
    }

    fn seek(&mut self, seconds: f64) -> Result<u64, String> {
        let target = (seconds * f64::from(self.sample_rate)).round().max(0.0) as usize;
        let target = target.min(self.total_frames);
        self.cursor_frames = target;
        Ok(target as u64)
    }
}

impl ApeSource {
    fn next_chunk(&mut self) -> Result<Vec<f32>, String> {
        if self.next_frame >= self.total_frames {
            return Ok(Vec::new());
        }

        let bytes = self
            .decoder
            .decode_frame(self.next_frame)
            .map_err(|error| error.to_string())?;
        self.next_frame += 1;

        let mut pcm = pcm_bytes_to_f32(&bytes, self.bits);
        if self.skip_frames > 0 {
            let skip = (self.skip_frames * self.channels).min(pcm.len());
            pcm.drain(..skip);
            self.skip_frames = 0;
        }
        Ok(pcm)
    }

    fn seek(&mut self, seconds: f64) -> Result<u64, String> {
        let target = (seconds * f64::from(self.decoder.info().sample_rate))
            .round()
            .max(0.0) as u64;
        let position = self.decoder.seek(target).map_err(|error| error.to_string())?;
        self.next_frame = position.frame_index;
        self.skip_frames = position.skip_samples as usize;
        Ok(position.actual_sample)
    }
}

/// Reads stream properties without decoding any audio. Used by the importer so
/// a library scan never pays for full WavPack or APE decoding.
pub fn inspect(path: &Path) -> Result<DecoderInfo, String> {
    match crate::probe::quick_container(path).as_str() {
        "wavpack" => {
            let mut bytes = std::fs::read(path).map_err(|error| error.to_string())?;
            trim_apev2(&mut bytes);
            let source = read_wavpack_info(&bytes)?;
            let frames = source
                .total_samples
                .unwrap_or_else(|| wavpack_total_frames(&bytes));
            Ok(DecoderInfo {
                container: "wavpack".to_string(),
                codec: if source.is_float {
                    "pcm_f32".to_string()
                } else {
                    pcm_codec_name(source.bits_per_sample as u16)
                },
                sample_rate: source.sample_rate,
                channels: source.channels as usize,
                duration_seconds: if source.sample_rate > 0 {
                    frames as f64 / f64::from(source.sample_rate)
                } else {
                    0.0
                },
            })
        }
        "ape" => {
            let file = File::open(path).map_err(|error| error.to_string())?;
            let decoder =
                ApeDecoder::new(BufReader::new(file)).map_err(|error| error.to_string())?;
            let stream = decoder.info();
            Ok(DecoderInfo {
                container: "ape".to_string(),
                codec: pcm_codec_name(stream.bits_per_sample),
                sample_rate: stream.sample_rate,
                channels: stream.channels as usize,
                duration_seconds: if stream.sample_rate > 0 {
                    stream.total_samples as f64 / f64::from(stream.sample_rate)
                } else {
                    0.0
                },
            })
        }
        _ => Ok(AudioDecoder::open(path)?.info().clone()),
    }
}

fn pcm_codec_name(bits: u16) -> String {
    match bits {
        8 => "pcm_u8".to_string(),
        24 => "pcm_s24".to_string(),
        32 => "pcm_s32".to_string(),
        _ => "pcm_s16".to_string(),
    }
}

struct WavPackInfo {
    sample_rate: u32,
    channels: u32,
    bits_per_sample: u32,
    is_float: bool,
    total_samples: Option<u64>,
    lossless: bool,
}

fn read_wavpack_info(bytes: &[u8]) -> Result<WavPackInfo, String> {
    let stream = wavicle::StreamInfo::scan(bytes).map_err(|error| error.to_string())?;
    Ok(WavPackInfo {
        sample_rate: stream.sample_rate,
        channels: stream.channels,
        bits_per_sample: stream.bits_per_sample,
        is_float: stream.is_float,
        total_samples: stream.total_samples,
        lossless: stream.lossless,
    })
}

fn wavpack_total_frames(bytes: &[u8]) -> u64 {
    let mut total = 0u64;
    for block in wavicle::Blocks::new(bytes).flatten() {
        let header = block.header;
        if header.block_samples > 0 {
            total = header.block_index + u64::from(header.block_samples);
        }
    }
    total
}

fn wavpack_sample_to_f32(sample: i32, bits: u32, is_float: bool) -> f32 {
    if is_float {
        return f32::from_bits(sample as u32);
    }
    let shift = bits.saturating_sub(1).min(31);
    let scale = (1i64 << shift) as f32;
    sample as f32 / scale
}

/// Converts little-endian integer PCM bytes to interleaved `f32`.
fn pcm_bytes_to_f32(bytes: &[u8], bits: u32) -> Vec<f32> {
    match bits {
        8 => bytes.iter().map(|byte| (*byte as i8) as f32 / 128.0).collect(),
        16 => bytes
            .chunks_exact(2)
            .map(|chunk| i16::from_le_bytes([chunk[0], chunk[1]]) as f32 / 32_768.0)
            .collect(),
        24 => bytes
            .chunks_exact(3)
            .map(|chunk| {
                let value =
                    ((chunk[2] as i32) << 16) | ((chunk[1] as i32) << 8) | (chunk[0] as i32);
                let signed = (value << 8) >> 8;
                signed as f32 / 8_388_608.0
            })
            .collect(),
        32 => bytes
            .chunks_exact(4)
            .map(|chunk| {
                i32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]) as f32
                    / 2_147_483_648.0
            })
            .collect(),
        _ => Vec::new(),
    }
}

/// Removes a trailing APEv2 tag (and ID3v1 chunk) so the WavPack block reader
/// is not asked to parse metadata as audio.
fn trim_apev2(bytes: &mut Vec<u8>) {
    if let Some((start, _, _)) = apev2_region(bytes) {
        bytes.truncate(start);
    }
}

/// Locates a trailing APEv2 tag.
///
/// Returns `(tag_start, items_start, footer_start)`, where `tag_start` includes
/// the optional tag header.
pub(crate) fn apev2_region(bytes: &[u8]) -> Option<(usize, usize, usize)> {
    let mut end = bytes.len();
    if end >= 128 && &bytes[end - 128..end - 125] == b"TAG" {
        end -= 128;
    }
    if end < 32 || &bytes[end - 32..end - 24] != b"APETAGEX" {
        return None;
    }

    let size = u32::from_le_bytes([
        bytes[end - 20],
        bytes[end - 19],
        bytes[end - 18],
        bytes[end - 17],
    ]) as usize;
    let flags = u32::from_le_bytes([
        bytes[end - 12],
        bytes[end - 11],
        bytes[end - 10],
        bytes[end - 9],
    ]);
    let header = if flags & 0x8000_0000 != 0 { 32 } else { 0 };

    let items_start = end.saturating_sub(size);
    let footer_start = end.saturating_sub(32);
    if items_start > footer_start {
        return None;
    }
    Some((items_start.saturating_sub(header), items_start, footer_start))
}

/// Reads the text items of a trailing APEv2 tag, in file order.
pub(crate) fn apev2_items(bytes: &[u8]) -> Vec<(String, String)> {
    let Some((_, mut offset, footer_start)) = apev2_region(bytes) else {
        return Vec::new();
    };

    let mut items = Vec::new();
    while offset + 8 <= footer_start {
        let value_size = u32::from_le_bytes([
            bytes[offset],
            bytes[offset + 1],
            bytes[offset + 2],
            bytes[offset + 3],
        ]) as usize;
        let flags = u32::from_le_bytes([
            bytes[offset + 4],
            bytes[offset + 5],
            bytes[offset + 6],
            bytes[offset + 7],
        ]);
        offset += 8;

        let key_end = bytes[offset..footer_start]
            .iter()
            .position(|byte| *byte == 0)
            .map(|index| offset + index);
        let Some(key_end) = key_end else { break };
        let key = String::from_utf8_lossy(&bytes[offset..key_end]).to_string();
        offset = key_end + 1;

        if offset + value_size > footer_start {
            break;
        }
        let value = &bytes[offset..offset + value_size];
        offset += value_size;

        // Bit 1 marks binary values; only text is useful here.
        if flags & 0b10 == 0 {
            let text = String::from_utf8_lossy(value).trim().to_string();
            if !text.is_empty() {
                items.push((key, text));
            }
        }
    }
    items
}

/// Reads the granule position of the last Ogg page.
///
/// Ogg stores the total number of samples in the final page header, so the
/// duration is available without decoding the file.
fn ogg_granule_duration(path: &Path, sample_rate: u32, pre_skip: u64, _opus: bool) -> Option<f64> {
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

    fn fixture(name: &str) -> PathBuf {
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
    fn decodes_wavpack() {
        let mut decoder = AudioDecoder::open(&fixture("tone.wv")).expect("open wavpack");
        assert_eq!(decoder.info().container, "wavpack");
        assert_eq!(decoder.info().sample_rate, 22050);
        assert_eq!(decoder.info().channels, 2);
        assert!((decoder.info().duration_seconds - 0.3).abs() < 0.02);

        let pcm = decode_all(&mut decoder);
        assert_eq!(pcm.len(), 6615 * 2);
        // Matches the reference decoder: sample 1 is 1586 / 32768.
        assert!((pcm[2] - 1586.0 / 32768.0).abs() < 1e-6);
    }

    #[test]
    fn decodes_ape_and_seeks() {
        let mut decoder = AudioDecoder::open(&fixture("tone.ape")).expect("open ape");
        assert_eq!(decoder.info().container, "ape");
        assert_eq!(decoder.info().sample_rate, 44_100);
        assert_eq!(decoder.info().channels, 2);
        assert!((decoder.info().duration_seconds - 1.0).abs() < 0.01);

        let pcm = decode_all(&mut decoder);
        assert_eq!(pcm.len(), 44_100 * 2);
        assert!((pcm[2] - 1002.0 / 32768.0).abs() < 1e-6);

        decoder.seek(0.5).expect("seek");
        let tail = decode_all(&mut decoder);
        assert!(!tail.is_empty());
        assert!(tail.len() < pcm.len(), "seek should skip the head");
        assert!((decoder.position_seconds() - 1.0).abs() < 0.02);
    }

    #[test]
    fn inspect_does_not_need_decoding() {
        for name in ["tone.wv", "tone.ape"] {
            let info = inspect(&fixture(name)).expect(name);
            assert!(info.duration_seconds > 0.2, "{name}");
            assert!(info.sample_rate > 0, "{name}");
            assert_eq!(info.channels, 2, "{name}");
        }
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
