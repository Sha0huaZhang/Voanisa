use crate::store::{Store, StoreError};
use rusqlite::{params, Connection, Row};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackRecord {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: String,
    pub track_number: Option<i64>,
    pub disc_number: Option<i64>,
    pub duration: f64,
    pub file_name: String,
    pub cover_file_name: Option<String>,
    pub format: String,
    pub content_hash: String,
    pub source: String,
    pub music_persistent_id: Option<String>,
    pub date_added: f64,
    pub sort_index: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewTrack {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: String,
    pub track_number: Option<i64>,
    pub disc_number: Option<i64>,
    pub duration: f64,
    pub file_name: String,
    pub cover_file_name: Option<String>,
    pub format: String,
    pub content_hash: String,
    pub source: String,
    pub music_persistent_id: Option<String>,
    pub date_added: f64,
}

impl NewTrack {
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        file_name: impl Into<String>,
        content_hash: impl Into<String>,
        date_added: f64,
    ) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            artist: String::new(),
            album: String::new(),
            album_artist: String::new(),
            track_number: None,
            disc_number: None,
            duration: 0.0,
            file_name: file_name.into(),
            cover_file_name: None,
            format: String::new(),
            content_hash: content_hash.into(),
            source: "local".to_string(),
            music_persistent_id: None,
            date_added,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TrackUpdate {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: String,
    pub track_number: Option<i64>,
    pub disc_number: Option<i64>,
    pub cover_file_name: Option<String>,
    pub music_persistent_id: Option<String>,
}

impl TrackUpdate {
    pub fn new(id: impl Into<String>, title: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            artist: String::new(),
            album: String::new(),
            album_artist: String::new(),
            track_number: None,
            disc_number: None,
            cover_file_name: None,
            music_persistent_id: None,
        }
    }
}

const SELECT_TRACKS: &str = "
    SELECT id, title, artist, album, album_artist, track_number, disc_number,
           duration, file_name, cover_file_name, format, content_hash, source,
           music_persistent_id, date_added, sort_index
    FROM tracks
";

impl Store {
    pub fn list_tracks(&self) -> Result<Vec<TrackRecord>, StoreError> {
        let mut statement = self
            .connection()
            .prepare(&format!("{SELECT_TRACKS} ORDER BY sort_index, date_added, id"))?;
        let rows = statement.query_map([], track_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(StoreError::from)
    }

    pub fn search_tracks(&self, query: &str) -> Result<Vec<TrackRecord>, StoreError> {
        let trimmed = query.trim();
        if trimmed.is_empty() {
            return self.list_tracks();
        }

        let pattern = format!("%{}%", escape_like(trimmed));
        let mut statement = self.connection().prepare(&format!(
            "{SELECT_TRACKS}
             WHERE title LIKE ?1 ESCAPE '!'
                OR artist LIKE ?1 ESCAPE '!'
                OR album LIKE ?1 ESCAPE '!'
                OR album_artist LIKE ?1 ESCAPE '!'
             ORDER BY sort_index, date_added, id"
        ))?;
        let rows = statement.query_map([pattern], track_from_row)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(StoreError::from)
    }

    pub fn insert_track(&self, track: &NewTrack) -> Result<TrackRecord, StoreError> {
        let transaction = self.connection().unchecked_transaction()?;
        let record = insert_track_tx(&transaction, track)?;
        transaction.commit()?;
        Ok(record)
    }

    pub fn insert_tracks(&self, tracks: &[NewTrack]) -> Result<Vec<TrackRecord>, StoreError> {
        let transaction = self.connection().unchecked_transaction()?;
        let mut records = Vec::with_capacity(tracks.len());
        for track in tracks {
            records.push(insert_track_tx(&transaction, track)?);
        }
        transaction.commit()?;
        Ok(records)
    }

    pub fn update_track(&self, update: &TrackUpdate) -> Result<(), StoreError> {
        let changed = self.connection().execute(
            "UPDATE tracks
             SET title = ?2, artist = ?3, album = ?4, album_artist = ?5,
                 track_number = ?6, disc_number = ?7, cover_file_name = ?8,
                 music_persistent_id = ?9
             WHERE id = ?1",
            params![
                update.id,
                update.title,
                update.artist,
                update.album,
                update.album_artist,
                update.track_number,
                update.disc_number,
                update.cover_file_name,
                update.music_persistent_id,
            ],
        )?;

        if changed == 0 {
            Err(StoreError::NotFound)
        } else {
            Ok(())
        }
    }

    pub fn delete_track(&self, id: &str) -> Result<bool, StoreError> {
        let changed = self
            .connection()
            .execute("DELETE FROM tracks WHERE id = ?1", [id])?;
        Ok(changed > 0)
    }

    /// Rewrites `sort_index` so it matches the given order.
    ///
    /// The list must contain every existing track exactly once; anything else
    /// is rejected before any row is changed.
    pub fn reorder_tracks(&self, ids: &[String]) -> Result<(), StoreError> {
        let connection = self.connection();
        let transaction = connection.unchecked_transaction()?;

        let total: i64 = transaction.query_row("SELECT COUNT(*) FROM tracks", [], |row| row.get(0))?;
        if ids.len() as i64 != total {
            return Err(StoreError::InvalidReorder);
        }

        let mut seen = HashSet::with_capacity(ids.len());
        for (index, id) in ids.iter().enumerate() {
            if !seen.insert(id) {
                return Err(StoreError::InvalidReorder);
            }
            let changed = transaction.execute(
                "UPDATE tracks SET sort_index = ?1 WHERE id = ?2",
                params![index as i64, id],
            )?;
            if changed == 0 {
                return Err(StoreError::InvalidReorder);
            }
        }

        transaction.commit()?;
        Ok(())
    }
}

fn insert_track_tx(connection: &Connection, track: &NewTrack) -> Result<TrackRecord, StoreError> {
    let sort_index: i64 = connection.query_row(
        "SELECT COALESCE(MAX(sort_index) + 1, 0) FROM tracks",
        [],
        |row| row.get(0),
    )?;

    connection.execute(
        "INSERT INTO tracks (
            id, title, artist, album, album_artist, track_number, disc_number,
            duration, file_name, cover_file_name, format, content_hash, source,
            music_persistent_id, date_added, sort_index
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)",
        params![
            track.id,
            track.title,
            track.artist,
            track.album,
            track.album_artist,
            track.track_number,
            track.disc_number,
            track.duration,
            track.file_name,
            track.cover_file_name,
            track.format,
            track.content_hash,
            track.source,
            track.music_persistent_id,
            track.date_added,
            sort_index,
        ],
    )?;

    Ok(TrackRecord {
        id: track.id.clone(),
        title: track.title.clone(),
        artist: track.artist.clone(),
        album: track.album.clone(),
        album_artist: track.album_artist.clone(),
        track_number: track.track_number,
        disc_number: track.disc_number,
        duration: track.duration,
        file_name: track.file_name.clone(),
        cover_file_name: track.cover_file_name.clone(),
        format: track.format.clone(),
        content_hash: track.content_hash.clone(),
        source: track.source.clone(),
        music_persistent_id: track.music_persistent_id.clone(),
        date_added: track.date_added,
        sort_index,
    })
}

fn track_from_row(row: &Row<'_>) -> rusqlite::Result<TrackRecord> {
    Ok(TrackRecord {
        id: row.get(0)?,
        title: row.get(1)?,
        artist: row.get(2)?,
        album: row.get(3)?,
        album_artist: row.get(4)?,
        track_number: row.get(5)?,
        disc_number: row.get(6)?,
        duration: row.get(7)?,
        file_name: row.get(8)?,
        cover_file_name: row.get(9)?,
        format: row.get(10)?,
        content_hash: row.get(11)?,
        source: row.get(12)?,
        music_persistent_id: row.get(13)?,
        date_added: row.get(14)?,
        sort_index: row.get(15)?,
    })
}

fn escape_like(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '!' | '%' | '_' => {
                escaped.push('!');
                escaped.push(character);
            }
            _ => escaped.push(character),
        }
    }
    escaped
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track(id: &str, title: &str) -> NewTrack {
        NewTrack::new(id, title, format!("{id}.mp3"), format!("hash-{id}"), 0.0)
    }

    #[test]
    fn insert_assigns_increasing_sort_indexes() {
        let store = Store::open_in_memory().expect("open store");

        let first = store.insert_track(&track("a", "A")).expect("insert first");
        let second = store.insert_track(&track("b", "B")).expect("insert second");

        assert_eq!(first.sort_index, 0);
        assert_eq!(second.sort_index, 1);
        assert_eq!(store.list_tracks().expect("list").len(), 2);
    }

    #[test]
    fn insert_batch_preserves_order() {
        let store = Store::open_in_memory().expect("open store");
        let records = store
            .insert_tracks(&[track("a", "A"), track("b", "B"), track("c", "C")])
            .expect("batch insert");

        assert_eq!(
            records.iter().map(|record| record.id.as_str()).collect::<Vec<_>>(),
            ["a", "b", "c"]
        );
        assert_eq!(records.iter().map(|record| record.sort_index).collect::<Vec<_>>(), [0, 1, 2]);
    }

    #[test]
    fn list_is_ordered_by_sort_index() {
        let store = Store::open_in_memory().expect("open store");
        store.insert_tracks(&[track("a", "A"), track("b", "B")]).expect("insert");
        store.reorder_tracks(&["b".to_string(), "a".to_string()]).expect("reorder");

        let titles: Vec<String> = store
            .list_tracks()
            .expect("list")
            .into_iter()
            .map(|record| record.title)
            .collect();
        assert_eq!(titles, ["B", "A"]);
    }

    #[test]
    fn update_changes_metadata() {
        let store = Store::open_in_memory().expect("open store");
        store.insert_track(&track("a", "Old")).expect("insert");

        let mut update = TrackUpdate::new("a", "New");
        update.artist = "Artist".to_string();
        update.album = "Album".to_string();
        update.album_artist = "Album Artist".to_string();
        update.track_number = Some(3);
        update.disc_number = Some(1);
        store.update_track(&update).expect("update");

        let record = store.list_tracks().expect("list").remove(0);
        assert_eq!(record.title, "New");
        assert_eq!(record.artist, "Artist");
        assert_eq!(record.album, "Album");
        assert_eq!(record.track_number, Some(3));
    }

    #[test]
    fn update_unknown_track_is_not_found() {
        let store = Store::open_in_memory().expect("open store");
        let result = store.update_track(&TrackUpdate::new("missing", "Missing"));
        assert!(matches!(result, Err(StoreError::NotFound)));
    }

    #[test]
    fn delete_removes_track_and_playlist_item() {
        let store = Store::open_in_memory().expect("open store");
        store.insert_track(&track("a", "A")).expect("insert");
        store
            .connection()
            .execute(
                "INSERT INTO playlists (id, name, sort_index, created_at) VALUES ('p', 'P', 0, 0)",
                [],
            )
            .expect("insert playlist");
        store
            .connection()
            .execute(
                "INSERT INTO playlist_items (playlist_id, track_id, position) VALUES ('p', 'a', 0)",
                [],
            )
            .expect("insert item");

        assert!(store.delete_track("a").expect("delete"));
        assert!(store.list_tracks().expect("list").is_empty());
        let items: i64 = store
            .connection()
            .query_row("SELECT COUNT(*) FROM playlist_items", [], |row| row.get(0))
            .expect("count");
        assert_eq!(items, 0);
    }

    #[test]
    fn search_matches_title_artist_and_album() {
        let store = Store::open_in_memory().expect("open store");
        let mut blue = track("a", "Blue Bird");
        blue.artist = "Ikimono".to_string();
        blue.album = "Naruto".to_string();
        let mut night = track("b", "夜曲");
        night.artist = "周杰伦".to_string();
        store.insert_tracks(&[blue, night]).expect("insert");

        assert_eq!(store.search_tracks("blue").expect("title search").len(), 1);
        assert_eq!(store.search_tracks("IKIMONO").expect("artist search").len(), 1);
        assert_eq!(store.search_tracks("Naruto").expect("album search").len(), 1);
        assert_eq!(store.search_tracks("周杰伦").expect("unicode search").len(), 1);
        assert!(store.search_tracks("missing").expect("no match").is_empty());
    }

    #[test]
    fn wildcard_characters_are_escaped() {
        let store = Store::open_in_memory().expect("open store");
        store.insert_track(&track("a", "100% Pure")).expect("insert");
        store.insert_track(&track("b", "100 Pure")).expect("insert");

        let results = store.search_tracks("100%").expect("search");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].title, "100% Pure");
    }

    #[test]
    fn reorder_rejects_incomplete_or_duplicate_lists() {
        let store = Store::open_in_memory().expect("open store");
        store.insert_tracks(&[track("a", "A"), track("b", "B")]).expect("insert");

        assert!(matches!(
            store.reorder_tracks(&["a".to_string()]),
            Err(StoreError::InvalidReorder)
        ));
        assert!(matches!(
            store.reorder_tracks(&["a".to_string(), "a".to_string()]),
            Err(StoreError::InvalidReorder)
        ));
        assert!(matches!(
            store.reorder_tracks(&["a".to_string(), "missing".to_string()]),
            Err(StoreError::InvalidReorder)
        ));
    }
}
