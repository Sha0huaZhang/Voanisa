pub mod cover;
pub mod decode;
pub mod hash;
pub mod library;
pub mod playlist;
pub mod probe;
pub mod store;
pub mod tags;

pub use cover::{write_square_cover, CoverResult};
pub use decode::{inspect, AudioDecoder, DecoderInfo};
pub use hash::{hash_bytes, hash_file};
pub use library::{NewTrack, TrackRecord, TrackUpdate};
pub use playlist::PlaylistRecord;
pub use probe::{detect, probe_path, quick_container, ProbeResult};
pub use store::{migrate, user_version, Store, StoreError, CURRENT_SCHEMA_VERSION};
pub use tags::{read_artwork, read_tags, write_artwork, write_tags, Artwork, TagWrite, TrackTags};
