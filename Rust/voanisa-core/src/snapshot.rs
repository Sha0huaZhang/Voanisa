//! The portable `library.json` snapshot.
//!
//! SQLite is the primary store, but the snapshot is what survives a broken
//! database and what users copy between machines. It used to be written by
//! Swift's JSONEncoder; owning it here keeps one writer for the whole library
//! format and makes the backup identical on every platform.
//!
//! Encoding notes:
//! * Keys are camelCase because the existing snapshots use that spelling.
//! * `dateAdded` is seconds since 2001-01-01, which is what Swift's default
//!   `Date` encoding produced. SQLite stores Unix seconds instead.

use std::collections::HashSet;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::library::{NewTrack, TrackRecord};
use crate::playlist::PlaylistRecord;
use crate::store::{Store, StoreError};

/// Seconds between 1970-01-01 and Apple's 2001-01-01 reference date.
const APPLE_REFERENCE_OFFSET: f64 = 978_307_200.0;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Snapshot {
    #[serde(default = "default_version")]
    pub version: i32,
    #[serde(default)]
    pub tracks: Vec<SnapshotTrack>,
    #[serde(default)]
    pub playlists: Vec<SnapshotPlaylist>,
}

impl Default for Snapshot {
    fn default() -> Self {
        Self {
            version: default_version(),
            tracks: Vec::new(),
            playlists: Vec::new(),
        }
    }
}

fn default_version() -> i32 {
    1
}

fn default_source() -> String {
    "local".to_string()
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotTrack {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub artist: String,
    #[serde(default)]
    pub album: String,
    #[serde(default)]
    pub duration: f64,
    pub file_name: String,
    #[serde(default)]
    pub cover_file_name: Option<String>,
    #[serde(default)]
    pub format: String,
    #[serde(default)]
    pub content_hash: String,
    #[serde(default)]
    pub date_added: f64,
    #[serde(default)]
    pub album_artist: String,
    #[serde(default)]
    pub track_number: Option<i64>,
    #[serde(default)]
    pub disc_number: Option<i64>,
    #[serde(default = "default_source")]
    pub source: String,
    #[serde(default, rename = "musicPersistentID")]
    pub music_persistent_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotPlaylist {
    pub id: String,
    pub name: String,
    #[serde(default, rename = "trackIDs")]
    pub track_ids: Vec<String>,
}

/// How much a snapshot operation touched, mostly for logging.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct SnapshotCounts {
    pub tracks: usize,
    pub playlists: usize,
}

/// Reads a snapshot without touching any database.
pub fn read_snapshot(path: &Path) -> Result<Snapshot, String> {
    let text =
        std::fs::read_to_string(path).map_err(|error| format!("{}: {error}", path.display()))?;
    serde_json::from_str(&text).map_err(|error| format!("{}: {error}", path.display()))
}

/// Builds the snapshot that currently lives in SQLite.
pub fn snapshot_from_store(db_path: &Path) -> Result<Snapshot, String> {
    let store = Store::open(db_path).map_err(store_error)?;
    let tracks = store.list_tracks().map_err(store_error)?;
    let playlists = store.list_playlists().map_err(store_error)?;

    Ok(Snapshot {
        version: default_version(),
        tracks: tracks.iter().map(snapshot_track).collect(),
        playlists: playlists.iter().map(snapshot_playlist).collect(),
    })
}

/// Writes `library.json` from the database. The database stays the source of
/// truth, so the snapshot can never disagree with what the app shows.
pub fn write_snapshot(db_path: &Path, out: &Path) -> Result<SnapshotCounts, String> {
    let snapshot = snapshot_from_store(db_path)?;
    let json = serde_json::to_string_pretty(&snapshot)
        .map_err(|error| format!("snapshot encode: {error}"))?;
    std::fs::write(out, json).map_err(|error| format!("{}: {error}", out.display()))?;

    Ok(SnapshotCounts {
        tracks: snapshot.tracks.len(),
        playlists: snapshot.playlists.len(),
    })
}

/// Restores a snapshot into a database.
///
/// Tracks are inserted when their id is unknown, and playlists are created with
/// whatever members survived, so importing the same file twice is harmless.
pub fn import_snapshot(json_path: &Path, db_path: &Path) -> Result<SnapshotCounts, String> {
    let snapshot = read_snapshot(json_path)?;
    let store = Store::open(db_path).map_err(store_error)?;

    let mut known: HashSet<String> = store
        .list_tracks()
        .map_err(store_error)?
        .into_iter()
        .map(|record| record.id)
        .collect();

    let mut pending = Vec::new();
    for track in &snapshot.tracks {
        if known.insert(track.id.clone()) {
            pending.push(track.to_new_track());
        }
    }
    if !pending.is_empty() {
        store.insert_tracks(&pending).map_err(store_error)?;
    }

    let existing_playlists: HashSet<String> = store
        .list_playlists()
        .map_err(store_error)?
        .into_iter()
        .map(|record| record.id)
        .collect();

    let mut created = 0;
    for playlist in &snapshot.playlists {
        if existing_playlists.contains(&playlist.id) {
            continue;
        }
        store
            .create_playlist(&playlist.id, &playlist.name)
            .map_err(store_error)?;
        let members: Vec<String> = playlist
            .track_ids
            .iter()
            .filter(|id| known.contains(*id))
            .cloned()
            .collect();
        if !members.is_empty() {
            store
                .set_playlist_tracks(&playlist.id, &members)
                .map_err(store_error)?;
        }
        created += 1;
    }

    Ok(SnapshotCounts {
        tracks: pending.len(),
        playlists: created,
    })
}

fn snapshot_track(record: &TrackRecord) -> SnapshotTrack {
    SnapshotTrack {
        id: record.id.clone(),
        title: record.title.clone(),
        artist: record.artist.clone(),
        album: record.album.clone(),
        duration: record.duration,
        file_name: record.file_name.clone(),
        cover_file_name: record.cover_file_name.clone(),
        format: record.format.clone(),
        content_hash: record.content_hash.clone(),
        date_added: record.date_added - APPLE_REFERENCE_OFFSET,
        album_artist: record.album_artist.clone(),
        track_number: record.track_number,
        disc_number: record.disc_number,
        source: record.source.clone(),
        music_persistent_id: record.music_persistent_id.clone(),
    }
}

impl SnapshotTrack {
    fn to_new_track(&self) -> NewTrack {
        NewTrack {
            id: self.id.clone(),
            title: self.title.clone(),
            artist: self.artist.clone(),
            album: self.album.clone(),
            album_artist: self.album_artist.clone(),
            track_number: self.track_number,
            disc_number: self.disc_number,
            duration: self.duration,
            file_name: self.file_name.clone(),
            cover_file_name: self.cover_file_name.clone(),
            format: self.format.clone(),
            content_hash: self.content_hash.clone(),
            source: self.source.clone(),
            music_persistent_id: self.music_persistent_id.clone(),
            date_added: self.date_added + APPLE_REFERENCE_OFFSET,
        }
    }
}

fn snapshot_playlist(record: &PlaylistRecord) -> SnapshotPlaylist {
    SnapshotPlaylist {
        id: record.id.clone(),
        name: record.name.clone(),
        track_ids: record.track_ids.clone(),
    }
}

fn store_error(error: StoreError) -> String {
    error.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(name: &str) -> std::path::PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "voanisa-snapshot-{}-{name}",
            std::process::id()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        directory
    }

    fn sample_track(id: &str, title: &str) -> NewTrack {
        let mut track = NewTrack::new(id, title, format!("{title}.mp3"), format!("hash-{id}"), 1_700_000_000.0);
        track.artist = "Artist".to_string();
        track.album = "Album".to_string();
        track.album_artist = "Album Artist".to_string();
        track.track_number = Some(3);
        track.disc_number = Some(1);
        track.duration = 199.5;
        track.format = "MP3".to_string();
        track.cover_file_name = Some("cover.jpg".to_string());
        track
    }

    #[test]
    fn writes_camel_case_json_with_reference_dates() {
        let directory = temp_dir("write");
        let db = directory.join("library.sqlite");
        let json = directory.join("library.json");

        {
            let store = Store::open(&db).unwrap();
            store.insert_track(&sample_track("track-1", "First")).unwrap();
            store.create_playlist("playlist-1", "Favourites").unwrap();
            store
                .set_playlist_tracks("playlist-1", &["track-1".to_string()])
                .unwrap();
        }

        let counts = write_snapshot(&db, &json).unwrap();
        assert_eq!(counts, SnapshotCounts { tracks: 1, playlists: 1 });

        let text = std::fs::read_to_string(&json).unwrap();
        assert!(text.contains("\"fileName\": \"First.mp3\""), "{text}");
        assert!(text.contains("\"trackIDs\""), "{text}");
        assert!(text.contains("\"albumArtist\": \"Album Artist\""), "{text}");

        let parsed: Snapshot = serde_json::from_str(&text).unwrap();
        assert_eq!(parsed.version, 1);
        assert_eq!(parsed.tracks[0].date_added, 1_700_000_000.0 - APPLE_REFERENCE_OFFSET);
        assert_eq!(parsed.playlists[0].track_ids, vec!["track-1".to_string()]);

        std::fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn imports_a_snapshot_into_an_empty_database() {
        let directory = temp_dir("import");
        let db = directory.join("library.sqlite");
        let json = directory.join("library.json");

        std::fs::write(
            &json,
            r#"{
              "version": 1,
              "tracks": [
                {"id": "t1", "title": "One", "fileName": "one.mp3",
                 "contentHash": "h1", "dateAdded": 100.0, "duration": 3.5},
                {"id": "t2", "title": "Two", "fileName": "two.mp3",
                 "contentHash": "h2", "dateAdded": 200.0, "duration": 4.5}
              ],
              "playlists": [{"id": "p1", "name": "Mix", "trackIDs": ["t1", "missing"]}]
            }"#,
        )
        .unwrap();

        let counts = import_snapshot(&json, &db).unwrap();
        assert_eq!(counts, SnapshotCounts { tracks: 2, playlists: 1 });

        let store = Store::open(&db).unwrap();
        let tracks = store.list_tracks().unwrap();
        assert_eq!(tracks.len(), 2);
        assert_eq!(tracks[0].date_added, 100.0 + APPLE_REFERENCE_OFFSET);
        assert_eq!(
            store.list_playlists().unwrap()[0].track_ids,
            vec!["t1".to_string()]
        );

        // Importing twice must not duplicate anything.
        let again = import_snapshot(&json, &db).unwrap();
        assert_eq!(again, SnapshotCounts { tracks: 0, playlists: 0 });

        std::fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn reads_snapshots_without_optional_fields() {
        let directory = temp_dir("legacy");
        let json = directory.join("library.json");
        std::fs::write(
            &json,
            r#"{"tracks":[{"id":"t1","title":"Old","fileName":"old.mp3"}]}"#,
        )
        .unwrap();

        let snapshot = read_snapshot(&json).unwrap();
        assert_eq!(snapshot.version, 1);
        assert_eq!(snapshot.tracks[0].artist, "");
        assert_eq!(snapshot.tracks[0].source, "local");
        assert_eq!(snapshot.tracks[0].date_added, 0.0);

        std::fs::remove_dir_all(&directory).ok();
    }
}
