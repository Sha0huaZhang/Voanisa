#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod player;

use player::Engine;
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tauri::State;
use voanisa_core::store::Store;
use voanisa_core::TrackRecord;

#[derive(Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
enum Repeat {
    Off,
    All,
    One,
}

struct AppState {
    engine: Arc<Mutex<Engine>>,
    root: PathBuf,
    /// Playback order as shown on screen; next/previous walk this list.
    order: Mutex<Vec<String>>,
    repeat: Mutex<Repeat>,
}

#[derive(Serialize)]
struct Status {
    playing: bool,
    position: f64,
    duration: f64,
    track_id: Option<String>,
    volume: f64,
    repeat: Repeat,
}

fn library_root() -> PathBuf {
    if let Ok(override_path) = std::env::var("VOANISA_LIBRARY") {
        if !override_path.is_empty() {
            return PathBuf::from(override_path);
        }
    }
    dirs::home_dir()
        .unwrap_or_default()
        .join("Music")
        .join("Voanisa")
}

fn open_store(root: &Path) -> Result<Store, String> {
    Store::open(&root.join("library.sqlite")).map_err(|error| error.to_string())
}

fn track_record(root: &Path, id: &str) -> Result<TrackRecord, String> {
    open_store(root)?
        .list_tracks()
        .map_err(|error| error.to_string())?
        .into_iter()
        .find(|track| track.id == id)
        .ok_or_else(|| "找不到这首歌".to_string())
}

fn track_path(root: &Path, track: &TrackRecord) -> PathBuf {
    root.join("Media").join(&track.file_name)
}

fn start_track(root: &Path, engine: &Arc<Mutex<Engine>>, id: &str) -> Result<(), String> {
    let track = track_record(root, id)?;
    let mut engine = engine.lock().map_err(|_| "播放器状态不可用")?;
    engine.load(&track_path(root, &track), id)?;
    engine.set_playing(true);
    Ok(())
}

#[tauri::command]
fn list_tracks(state: State<'_, AppState>) -> Result<Vec<TrackRecord>, String> {
    let store = open_store(&state.root)?;
    match store.list_tracks() {
        Ok(tracks) => {
            eprintln!("list_tracks: {} 首（{}）", tracks.len(), state.root.display());
            Ok(tracks)
        }
        Err(error) => {
            eprintln!("list_tracks 失败：{error}");
            Err(error.to_string())
        }
    }
}

/// The order the list is showing. Next/previous walk this, matching what the
/// user sees rather than the database's own ordering.
#[tauri::command]
fn set_queue(ids: Vec<String>, state: State<'_, AppState>) {
    if let Ok(mut order) = state.order.lock() {
        *order = ids;
    }
}

#[tauri::command]
fn play_track(id: String, state: State<'_, AppState>) -> Result<(), String> {
    start_track(&state.root, &state.engine, &id)
}

#[tauri::command]
fn play_offset(offset: i64, state: State<'_, AppState>) -> Result<(), String> {
    let order = state.order.lock().map_err(|_| "播放列表不可用")?.clone();
    if order.is_empty() {
        return Ok(());
    }

    let current = state
        .engine
        .lock()
        .map_err(|_| "播放器状态不可用")?
        .track_id();

    let Some(current) = current else {
        return start_track(&state.root, &state.engine, &order[0]);
    };
    let Some(index) = order.iter().position(|id| id == &current) else {
        // The playing song is not in the visible list: there is no safe anchor.
        return Ok(());
    };

    let length = order.len() as i64;
    let repeat_all = *state.repeat.lock().map_err(|_| "循环状态不可用")? == Repeat::All;
    let mut target = index as i64 + offset;
    if target < 0 || target >= length {
        if !repeat_all {
            return Ok(());
        }
        target = target.rem_euclid(length);
    }

    start_track(&state.root, &state.engine, &order[target as usize])
}

#[tauri::command]
fn toggle_play(state: State<'_, AppState>) -> Result<bool, String> {
    let mut engine = state.engine.lock().map_err(|_| "播放器状态不可用")?;
    engine.toggle();
    Ok(engine.is_playing())
}

#[tauri::command]
fn seek(seconds: f64, state: State<'_, AppState>) -> Result<(), String> {
    let mut engine = state.engine.lock().map_err(|_| "播放器状态不可用")?;
    engine.seek(seconds);
    Ok(())
}

#[tauri::command]
fn set_volume(volume: f64, state: State<'_, AppState>) -> Result<(), String> {
    let mut engine = state.engine.lock().map_err(|_| "播放器状态不可用")?;
    engine.set_volume(volume);
    Ok(())
}

#[tauri::command]
fn cycle_repeat(state: State<'_, AppState>) -> Result<Repeat, String> {
    let mut repeat = state.repeat.lock().map_err(|_| "循环状态不可用")?;
    *repeat = match *repeat {
        Repeat::Off => Repeat::All,
        Repeat::All => Repeat::One,
        Repeat::One => Repeat::Off,
    };
    Ok(*repeat)
}

#[tauri::command]
fn status(state: State<'_, AppState>) -> Result<Status, String> {
    let engine = state.engine.lock().map_err(|_| "播放器状态不可用")?;
    let repeat = *state.repeat.lock().map_err(|_| "循环状态不可用")?;
    Ok(Status {
        playing: engine.is_playing(),
        position: engine.position(),
        duration: engine.duration(),
        track_id: engine.track_id(),
        volume: engine.volume(),
        repeat,
    })
}

#[tauri::command]
fn reveal_track(id: String, state: State<'_, AppState>) -> Result<(), String> {
    let track = track_record(&state.root, &id)?;
    reveal(&track_path(&state.root, &track))
}

#[cfg(target_os = "macos")]
fn reveal(path: &Path) -> Result<(), String> {
    std::process::Command::new("open")
        .arg("-R")
        .arg(path)
        .spawn()
        .map(|_| ())
        .map_err(|error| error.to_string())
}

#[cfg(target_os = "windows")]
fn reveal(path: &Path) -> Result<(), String> {
    std::process::Command::new("explorer")
        .arg(format!("/select,{}", path.display()))
        .spawn()
        .map(|_| ())
        .map_err(|error| error.to_string())
}

#[cfg(all(unix, not(target_os = "macos")))]
fn reveal(path: &Path) -> Result<(), String> {
    let parent = path.parent().unwrap_or(path);
    std::process::Command::new("xdg-open")
        .arg(parent)
        .spawn()
        .map(|_| ())
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn library_root_info(state: State<'_, AppState>) -> String {
    state.root.display().to_string()
}

fn main() {
    let engine = Arc::new(Mutex::new(Engine::new()));
    player::spawn_output(engine.clone());

    tauri::Builder::default()
        .manage(AppState {
            engine,
            root: library_root(),
            order: Mutex::new(Vec::new()),
            repeat: Mutex::new(Repeat::Off),
        })
        .invoke_handler(tauri::generate_handler![
            list_tracks,
            set_queue,
            play_track,
            play_offset,
            toggle_play,
            seek,
            set_volume,
            cycle_repeat,
            status,
            reveal_track,
            library_root_info
        ])
        .run(tauri::generate_context!())
        .expect("failed to run the Voanisa web shell");
}
