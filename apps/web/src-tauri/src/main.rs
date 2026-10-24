#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod player;

use player::Engine;
use serde::Serialize;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tauri::State;
use voanisa_core::store::Store;
use voanisa_core::TrackRecord;

struct AppState {
    engine: Arc<Mutex<Engine>>,
    root: PathBuf,
}

#[derive(Serialize)]
struct Status {
    playing: bool,
    position: f64,
    duration: f64,
    track_id: Option<String>,
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

fn open_store(root: &PathBuf) -> Result<Store, String> {
    Store::open(&root.join("library.sqlite")).map_err(|error| error.to_string())
}

#[tauri::command]
fn list_tracks(state: State<'_, AppState>) -> Result<Vec<TrackRecord>, String> {
    let store = open_store(&state.root)?;
    match store.list_tracks() {
        Ok(tracks) => {
            eprintln!(
                "list_tracks: {} 首（{}）",
                tracks.len(),
                state.root.display()
            );
            Ok(tracks)
        }
        Err(error) => {
            eprintln!("list_tracks 失败：{error}");
            Err(error.to_string())
        }
    }
}

#[tauri::command]
fn play_track(id: String, state: State<'_, AppState>) -> Result<(), String> {
    let track = open_store(&state.root)?
        .list_tracks()
        .map_err(|error| error.to_string())?
        .into_iter()
        .find(|track| track.id == id)
        .ok_or("找不到这首歌")?;

    let path = state.root.join("Media").join(&track.file_name);
    let mut engine = state.engine.lock().map_err(|_| "播放器状态不可用")?;
    engine.load(&path, &id)?;
    engine.set_playing(true);
    Ok(())
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
fn status(state: State<'_, AppState>) -> Result<Status, String> {
    let engine = state.engine.lock().map_err(|_| "播放器状态不可用")?;
    Ok(Status {
        playing: engine.is_playing(),
        position: engine.position(),
        duration: engine.duration(),
        track_id: engine.track_id(),
    })
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
        })
        .invoke_handler(tauri::generate_handler![
            list_tracks,
            play_track,
            toggle_play,
            seek,
            status,
            library_root_info
        ])
        .run(tauri::generate_context!())
        .expect("failed to run the Voanisa web shell");
}
