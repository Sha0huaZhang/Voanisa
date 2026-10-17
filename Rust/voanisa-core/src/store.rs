use rusqlite::Connection;
use std::fmt;
use std::path::Path;
use std::time::Duration;

pub const CURRENT_SCHEMA_VERSION: i32 = 1;

#[derive(Debug)]
pub enum StoreError {
    Sqlite(rusqlite::Error),
    UnsupportedSchema { found: i32, supported: i32 },
    InvalidReorder,
    DuplicateTrack,
    NotFound,
}

impl fmt::Display for StoreError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            StoreError::Sqlite(error) => write!(formatter, "sqlite error: {error}"),
            StoreError::UnsupportedSchema { found, supported } => write!(
                formatter,
                "library schema {found} is newer than supported schema {supported}"
            ),
            StoreError::InvalidReorder => {
                write!(formatter, "reorder must contain every track exactly once")
            }
            StoreError::DuplicateTrack => write!(formatter, "track list contains duplicate ids"),
            StoreError::NotFound => write!(formatter, "track not found"),
        }
    }
}

impl std::error::Error for StoreError {}

impl From<rusqlite::Error> for StoreError {
    fn from(error: rusqlite::Error) -> Self {
        StoreError::Sqlite(error)
    }
}

/// A migrated SQLite library.
///
/// M1-1 only establishes the schema and migration path. CRUD and the Swift
/// bridge follow in later tasks.
pub struct Store {
    connection: Connection,
}

impl Store {
    pub fn open(path: &Path) -> Result<Self, StoreError> {
        let connection = Connection::open(path)?;
        Self::prepare(connection, true)
    }

    pub fn open_in_memory() -> Result<Self, StoreError> {
        let connection = Connection::open_in_memory()?;
        Self::prepare(connection, false)
    }

    pub fn from_connection(connection: Connection) -> Result<Self, StoreError> {
        Self::prepare(connection, false)
    }

    pub fn connection(&self) -> &Connection {
        &self.connection
    }

    pub fn schema_version(&self) -> Result<i32, StoreError> {
        user_version(&self.connection)
    }

    pub fn table_exists(&self, name: &str) -> Result<bool, StoreError> {
        let count: i64 = self.connection.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
            [name],
            |row| row.get(0),
        )?;
        Ok(count > 0)
    }

    fn prepare(connection: Connection, wal: bool) -> Result<Self, StoreError> {
        connection.pragma_update(None, "foreign_keys", "ON")?;
        connection.busy_timeout(Duration::from_secs(5))?;

        if wal {
            // PRAGMA journal_mode returns a row, so query it instead of using
            // pragma_update (which would report returned results as an error).
            let _mode: String =
                connection.query_row("PRAGMA journal_mode = WAL", [], |row| row.get(0))?;
        }

        migrate(&connection)?;
        Ok(Self { connection })
    }
}

pub fn migrate(connection: &Connection) -> Result<(), StoreError> {
    let version = user_version(connection)?;

    if version > CURRENT_SCHEMA_VERSION {
        return Err(StoreError::UnsupportedSchema {
            found: version,
            supported: CURRENT_SCHEMA_VERSION,
        });
    }

    if version < 1 {
        let transaction = connection.unchecked_transaction()?;
        transaction.execute_batch(MIGRATION_1)?;
        transaction.pragma_update(None, "user_version", 1)?;
        transaction.commit()?;
    }

    Ok(())
}

pub fn user_version(connection: &Connection) -> Result<i32, StoreError> {
    Ok(connection.pragma_query_value(None, "user_version", |row| row.get(0))?)
}

const MIGRATION_1: &str = r#"
CREATE TABLE IF NOT EXISTS tracks (
    id                  TEXT PRIMARY KEY NOT NULL,
    title               TEXT NOT NULL,
    artist              TEXT NOT NULL DEFAULT '',
    album               TEXT NOT NULL DEFAULT '',
    album_artist        TEXT NOT NULL DEFAULT '',
    track_number        INTEGER,
    disc_number         INTEGER,
    duration            REAL NOT NULL DEFAULT 0,
    file_name           TEXT NOT NULL UNIQUE,
    cover_file_name     TEXT,
    format              TEXT NOT NULL DEFAULT '',
    content_hash        TEXT NOT NULL,
    source              TEXT NOT NULL DEFAULT 'local'
                        CHECK (source IN ('local', 'music')),
    music_persistent_id TEXT,
    date_added          REAL NOT NULL,
    sort_index          INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_tracks_sort ON tracks(sort_index);
CREATE INDEX IF NOT EXISTS idx_tracks_hash ON tracks(content_hash);
CREATE INDEX IF NOT EXISTS idx_tracks_album ON tracks(album_artist, album);
CREATE INDEX IF NOT EXISTS idx_tracks_music_id ON tracks(music_persistent_id);

CREATE TABLE IF NOT EXISTS playlists (
    id          TEXT PRIMARY KEY NOT NULL,
    name        TEXT NOT NULL,
    sort_index  INTEGER NOT NULL,
    created_at  REAL NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_playlists_sort ON playlists(sort_index);

CREATE TABLE IF NOT EXISTS playlist_items (
    playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    track_id    TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    position    INTEGER NOT NULL,
    PRIMARY KEY (playlist_id, position),
    UNIQUE (playlist_id, track_id)
);

CREATE INDEX IF NOT EXISTS idx_playlist_items_track ON playlist_items(track_id);

CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
);
"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migration_creates_tables_and_sets_version() {
        let store = Store::open_in_memory().expect("open in-memory store");
        assert_eq!(store.schema_version().expect("schema version"), CURRENT_SCHEMA_VERSION);

        for table in ["tracks", "playlists", "playlist_items", "settings"] {
            assert!(
                store.table_exists(table).expect("table lookup"),
                "missing table {table}"
            );
        }
    }

    #[test]
    fn migration_is_idempotent() {
        let store = Store::open_in_memory().expect("open in-memory store");
        migrate(store.connection()).expect("second migration");
        assert_eq!(store.schema_version().expect("schema version"), CURRENT_SCHEMA_VERSION);
    }

    #[test]
    fn refuses_a_newer_schema() {
        let connection = Connection::open_in_memory().expect("open connection");
        connection
            .pragma_update(None, "user_version", 99)
            .expect("set user version");

        let result = Store::from_connection(connection);
        assert!(matches!(
            result,
            Err(StoreError::UnsupportedSchema { found: 99, supported: 1 })
        ));
    }

    #[test]
    fn foreign_keys_cascade_from_playlist_items() {
        let store = Store::open_in_memory().expect("open in-memory store");
        let connection = store.connection();

        connection
            .execute(
                "INSERT INTO tracks (id, title, file_name, content_hash, date_added, sort_index)
                 VALUES ('track-1', 'Title', 'track-1.mp3', 'hash-1', 0, 0)",
                [],
            )
            .expect("insert track");
        connection
            .execute(
                "INSERT INTO playlists (id, name, sort_index, created_at)
                 VALUES ('playlist-1', 'Playlist', 0, 0)",
                [],
            )
            .expect("insert playlist");
        connection
            .execute(
                "INSERT INTO playlist_items (playlist_id, track_id, position)
                 VALUES ('playlist-1', 'track-1', 0)",
                [],
            )
            .expect("insert playlist item");

        connection
            .execute("DELETE FROM playlists WHERE id = 'playlist-1'", [])
            .expect("delete playlist");

        let remaining: i64 = connection
            .query_row("SELECT COUNT(*) FROM playlist_items", [], |row| row.get(0))
            .expect("count playlist items");
        assert_eq!(remaining, 0);
    }
}
