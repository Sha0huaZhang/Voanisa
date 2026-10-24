use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::{Arc, Mutex};
use std::thread;
use voanisa_core::AudioDecoder;

/// Playback state shared between the Tauri commands and the audio callback.
///
/// The decoder hands out interleaved `f32` at the file's own rate; the output
/// device usually runs at another one, so the callback resamples linearly while
/// filling each buffer. Keeping the decoder here (rather than in a separate
/// thread with a ring buffer) is enough for the P0 probe; it can move to a
/// producer thread once we care about glitch-free output under load.
pub struct Engine {
    decoder: Option<AudioDecoder>,
    playing: bool,
    track_id: Option<String>,
    source_rate: f64,
    target_rate: f64,
    source_channels: usize,
    out_channels: usize,
    volume: f32,
    /// Interleaved source samples that have not been played yet.
    buffer: Vec<f32>,
    /// How many whole frames in `buffer` are valid.
    valid_frames: usize,
    /// Fractional read position inside `buffer`, in frames.
    cursor: f64,
    scratch: Vec<f32>,
    eof: bool,
    duration: f64,
}

impl Engine {
    pub fn new() -> Self {
        Self {
            decoder: None,
            playing: false,
            track_id: None,
            source_rate: 44_100.0,
            target_rate: 44_100.0,
            source_channels: 2,
            out_channels: 2,
            volume: 0.8,
            buffer: Vec::new(),
            valid_frames: 0,
            cursor: 0.0,
            scratch: Vec::new(),
            eof: false,
            duration: 0.0,
        }
    }

    pub fn set_output(&mut self, target_rate: f64, out_channels: usize) {
        self.target_rate = target_rate;
        self.out_channels = out_channels.max(1);
    }

    pub fn load(&mut self, path: &std::path::Path, track_id: &str) -> Result<(), String> {
        let decoder = AudioDecoder::open(path)?;
        let info = decoder.info().clone();
        self.source_rate = info.sample_rate.max(1) as f64;
        self.source_channels = info.channels.max(1);
        self.duration = info.duration_seconds;
        self.decoder = Some(decoder);
        self.track_id = Some(track_id.to_string());
        self.buffer.clear();
        self.valid_frames = 0;
        self.cursor = 0.0;
        self.eof = false;
        Ok(())
    }

    pub fn set_playing(&mut self, playing: bool) {
        self.playing = playing;
    }

    pub fn is_playing(&self) -> bool {
        self.playing
    }

    pub fn toggle(&mut self) {
        self.playing = !self.playing;
    }

    pub fn seek(&mut self, seconds: f64) {
        let Some(decoder) = self.decoder.as_mut() else {
            return;
        };
        if decoder.seek(seconds.max(0.0)).is_ok() {
            self.buffer.clear();
            self.valid_frames = 0;
            self.cursor = 0.0;
            self.eof = false;
        }
    }

    pub fn position(&self) -> f64 {
        let delivered = self
            .decoder
            .as_ref()
            .map(|d| d.position_seconds())
            .unwrap_or(0.0);
        let buffered = self.valid_frames as f64 / self.source_rate.max(1.0);
        (delivered - buffered).max(0.0)
    }

    pub fn duration(&self) -> f64 {
        self.duration
    }

    pub fn track_id(&self) -> Option<String> {
        self.track_id.clone()
    }

    /// Fills one output buffer. Runs on the audio thread: no allocation in the
    /// steady state, and it never blocks for longer than one decode chunk.
    pub fn fill(&mut self, out: &mut [f32]) {
        out.fill(0.0);
        if !self.playing || self.decoder.is_none() || self.out_channels == 0 {
            return;
        }

        let out_frames = out.len() / self.out_channels;
        if out_frames == 0 {
            return;
        }

        let ratio = if self.target_rate > 0.0 {
            self.source_rate / self.target_rate
        } else {
            1.0
        };
        let span = out_frames.saturating_sub(1) as f64 * ratio;
        let needed = (self.cursor + span).ceil() as usize + 2;
        self.ensure(needed);

        let src_ch = self.source_channels.max(1);
        for i in 0..out_frames {
            let t = self.cursor + i as f64 * ratio;
            let base = t.floor() as usize;
            if base + 1 >= self.valid_frames {
                break;
            }
            let frac = (t - base as f64) as f32;
            for c in 0..self.out_channels {
                let sc = if c < src_ch { c } else { 0 };
                let a = self.buffer[base * src_ch + sc];
                let b = self.buffer[(base + 1) * src_ch + sc];
                out[i * self.out_channels + c] = (a + (b - a) * frac) * self.volume;
            }
        }

        // Consume what has been played; keep the last frame for interpolation.
        let consumed = (self.cursor + span).floor() as usize;
        let consumed = consumed.min(self.valid_frames.saturating_sub(1));
        if consumed > 0 {
            self.buffer.drain(0..consumed * src_ch);
            self.valid_frames -= consumed;
            self.cursor -= consumed as f64;
        }
    }

    fn ensure(&mut self, frames: usize) {
        while self.valid_frames < frames && !self.eof {
            let Some(decoder) = self.decoder.as_mut() else {
                return;
            };
            let src_ch = self.source_channels.max(1);
            let want = (frames - self.valid_frames).max(2048);
            let len = want * src_ch;
            if self.scratch.len() < len {
                self.scratch.resize(len, 0.0);
            }
            match decoder.read(&mut self.scratch[..len]) {
                Ok(0) => self.eof = true,
                Ok(n) => {
                    self.buffer.extend_from_slice(&self.scratch[..n]);
                    self.valid_frames += n / src_ch;
                }
                Err(_) => self.eof = true,
            }
        }
    }
}

/// Opens the default output device on a thread that keeps the stream alive.
///
/// `cpal::Stream` is not `Send` on every backend, so the stream never leaves the
/// thread that created it; the Tauri commands only touch the shared `Engine`.
pub fn spawn_output(engine: Arc<Mutex<Engine>>) {
    thread::spawn(move || match build_stream(engine) {
        Ok(stream) => {
            if let Err(error) = stream.play() {
                eprintln!("无法开始播放：{error}");
                return;
            }
            loop {
                thread::park();
            }
        }
        Err(error) => eprintln!("音频输出不可用：{error}"),
    });
}

fn build_stream(engine: Arc<Mutex<Engine>>) -> Result<cpal::Stream, Box<dyn std::error::Error>> {
    let host = cpal::default_host();
    let device = host
        .default_output_device()
        .ok_or("没有可用的音频输出设备")?;
    let supported = device.default_output_config()?;
    let sample_format = supported.sample_format();
    let config: cpal::StreamConfig = supported.into();
    let out_channels = config.channels as usize;
    let target_rate = config.sample_rate.0 as f64;

    if let Ok(mut shared) = engine.lock() {
        shared.set_output(target_rate, out_channels);
    }

    let err_fn = |error| eprintln!("音频流错误：{error}");
    let shared = engine.clone();
    let stream = match sample_format {
        cpal::SampleFormat::F32 => device.build_output_stream(
            &config,
            move |data: &mut [f32], _| {
                if let Ok(mut engine) = shared.lock() {
                    engine.fill(data);
                }
            },
            err_fn,
            None,
        )?,
        other => return Err(format!("暂不支持的输出采样格式：{other:?}").into()),
    };
    Ok(stream)
}
