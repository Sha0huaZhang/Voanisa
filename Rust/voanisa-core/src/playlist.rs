use crate::store::{Store, StoreError};
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlaylistRecord {
    pub id: String,
    pub name: String,
    pub sort_index: i64,
    pub track_ids: Vec<String>,
}

impl Store {
    pub fn list_playlists(&self) -> Result<Vec<PlaylistRecord>, StoreError> {
        let rows: Vec<(String, String, i64)> = {
            let mut statement = self.connection().prepare(
                "SELECT id, name, sort_index
                 FROM playlists
                 ORDER BY sort_index, created_at, id",
            )?;
            let rows = statement.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            })?;
            rows.collect::<Result<Vec<_>, _>>()?
        };

        let mut playlists = Vec::with_capacity(rows.len());
        for (id, name, sort_index) in rows {
            playlists.push(PlaylistRecord {
                track_ids: self.playlist_track_ids(&id)?,
                id,
                name,
                sort_index,
            });
        }
        Ok(playlists)
    }

    pub fn create_playlist(&self, id: &str, name: &str) -> Result<PlaylistRecord, StoreError> {
        let name = valid_name(name)?;
        let sort_index: i64 = self.connection().query_row(
            "SELECT COALESCE(MAX(sort_index) + 1, 0) FROM playlists",
            [],
            |row| row.get(0),
        )?;
        let created_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_secs_f64())
            .unwrap_or(0.0);

        self.connection().execute(
            "INSERT INTO playlists (id, name, sort_index, created_at)
             VALUES (?1, ?2, ?3, ?4)",
            params![id, name, sort_index, created_at],
        )?;

        Ok(PlaylistRecord {
            id: id.to_string(),
            name: name.to_string(),
            sort_index,
            track_ids: Vec::new(),
        })
    }

    pub fn rename_playlist(&self, id: &str, name: &str) -> Result<(), StoreError> {
        let name = valid_name(name)?;
        let changed = self.connection().execute(
            "UPDATE playlists SET name = ?2 WHERE id = ?1",
            params![id, name],
        )?;

        if changed == 0 {
            Err(StoreError::NotFound)
        } else {
            Ok(())
        }
    }

    pub fn delete_playlist(&self, id: &str) -> Result<bool, StoreError> {
        let changed = self
            .connection()
            .execute("DELETE FROM playlists WHERE id = ?1", [id])?;
        Ok(changed > 0)
    }

    /// Replaces playlist membership and order.
    pub fn set_playlist_tracks(
        &self,
        playlist_id: &str,
        track_ids: &[String],
    ) -> Result<(), StoreError> {
        let mut seen = HashSet::with_capacity(track_ids.len());
        for id in track_ids {
            if !seen.insert(id) {
                return Err(StoreError::DuplicateTrack);
            }
        }

        let connection = self.connection();
        let exists: Option<i64> = connection
            .query_row(
                "SELECT 1 FROM playlists WHERE id = ?1",
                [playlist_id],
                |row| row.get(0),
            )
            .optional()?;
        if exists.is_none() {
            return Err(StoreError::NotFound);
        }

        let transaction = connection.unchecked_transaction()?;
        transaction.execute(
            "DELETE FROM playlist_items WHERE playlist_id = ?1",
            [playlist_id],
        )?;

        for (position, track_id) in track_ids.iter().enumerate() {
            transaction.execute(
                "INSERT INTO playlist_items (playlist_id, track_id, position)
                 VALUES (?1, ?2, ?3)",
                params![playlist_id, track_id, position as i64],
            )?;
        }

        transaction.commit()?;
        Ok(())
    }

    fn playlist_track_ids(&self, playlist_id: &str) -> Result<Vec<String>, StoreError> {
        let mut statement = self.connection().prepare(
            "SELECT track_id
             FROM playlist_items
             WHERE playlist_id = ?1
             ORDER BY position",
        )?;
        let rows = statement.query_map([playlist_id], |row| row.get::<_, String>(0))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(StoreError::from)
    }
}

fn valid_name(name: &str) -> Result<&str, StoreError> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        Err(StoreError::InvalidPlaylistName)
    } else {
        Ok(trimmed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library::NewTrack;

    fn track(id: &str) -> NewTrack {
        NewTrack::new(
            id,
            id.to_uppercase(),
            format!("{id}.mp3"),
            format!("hash-{id}"),
            0.0,
        )
    }

    #[test]
    fn create_list_rename_and_delete() {
        let store = Store::open_in_memory().expect("open store");

        let created = store
            .create_playlist("p1", "  Favorites  ")
            .expect("create first");
        assert_eq!(created.name, "Favorites");
        assert_eq!(created.sort_index, 0);
        assert!(created.track_ids.is_empty());

        let second = store.create_playlist("p2", "Later").expect("create second");
        assert_eq!(second.sort_index, 1);
        assert_eq!(
            store
                .list_playlists()
                .expect("list")
                .iter()
                .map(|playlist| playlist.name.as_str())
                .collect::<Vec<_>>(),
            ["Favorites", "Later"]
        );

        store.rename_playlist("p1", "Best").expect("rename");
        assert_eq!(store.list_playlists().expect("list")[0].name, "Best");

        assert!(store.delete_playlist("p1").expect("delete"));
        assert_eq!(store.list_playlists().expect("list").len(), 1);
    }

    #[test]
    fn set_tracks_orders_and_replaces_membership() {
        let store = Store::open_in_memory().expect("open store");
        store
            .insert_tracks(&[track("a"), track("b"), track("c")])
            .expect("insert tracks");
        store.create_playlist("p", "Playlist").expect("create");

        store
            .set_playlist_tracks("p", &["c".to_string(), "a".to_string()])
            .expect("set tracks");
        assert_eq!(
            store.list_playlists().expect("list")[0].track_ids,
            ["c", "a"]
        );

        store
            .set_playlist_tracks("p", &["b".to_string()])
            .expect("replace tracks");
        assert_eq!(store.list_playlists().expect("list")[0].track_ids, ["b"]);

        store.set_playlist_tracks("p", &[]).expect("clear tracks");
        assert!(store.list_playlists().expect("list")[0]
            .track_ids
            .is_empty());
    }

    #[test]
    fn rejects_invalid_names_missing_playlists_and_duplicates() {
        let store = Store::open_in_memory().expect("open store");

        assert!(matches!(
            store.create_playlist("p", "   "),
            Err(StoreError::InvalidPlaylistName)
        ));
        assert!(matches!(
            store.rename_playlist("missing", "Name"),
            Err(StoreError::NotFound)
        ));
        assert!(matches!(
            store.set_playlist_tracks("missing", &[]),
            Err(StoreError::NotFound)
        ));

        store.create_playlist("p", "Playlist").expect("create");
        assert!(matches!(
            store.rename_playlist("p", " "),
            Err(StoreError::InvalidPlaylistName)
        ));
        assert!(matches!(
            store.set_playlist_tracks("p", &["a".to_string(), "a".to_string()]),
            Err(StoreError::DuplicateTrack)
        ));
        assert!(!store.delete_playlist("missing").expect("delete missing"));
    }

    #[test]
    fn deleting_a_track_removes_it_from_playlists() {
        let store = Store::open_in_memory().expect("open store");
        store
            .insert_tracks(&[track("a"), track("b")])
            .expect("insert tracks");
        store.create_playlist("p", "Playlist").expect("create");
        store
            .set_playlist_tracks("p", &["a".to_string(), "b".to_string()])
            .expect("set tracks");

        store.delete_track("a").expect("delete track");

        assert_eq!(store.list_playlists().expect("list")[0].track_ids, ["b"]);
    }
}
