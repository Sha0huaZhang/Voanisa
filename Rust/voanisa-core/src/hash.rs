//! Content hashing.
//!
//! The library deduplicates imports by the SHA-256 of the copied file. Keeping
//! the hash in the portable core means the same bytes always produce the same
//! identifier on every platform, and the import path no longer needs a platform
//! crypto framework.

use sha2::{Digest, Sha256};
use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;

/// Streams `path` through SHA-256 and returns lowercase hex.
///
/// Reads in 1 MiB chunks: music files are routinely tens of megabytes, so the
/// whole file never needs to be in memory.
pub fn hash_file(path: &Path) -> Result<String, String> {
    let file = File::open(path).map_err(|error| format!("{}: {error}", path.display()))?;
    let mut reader = BufReader::with_capacity(1 << 20, file);
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1 << 20];

    loop {
        let read = reader
            .read(&mut buffer)
            .map_err(|error| format!("{}: {error}", path.display()))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }

    Ok(to_hex(&hasher.finalize()))
}

/// Hashes an in-memory buffer. Kept for tests and for callers that already hold
/// the bytes (for example a decoded stream).
pub fn hash_bytes(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    to_hex(&hasher.finalize())
}

fn to_hex(digest: &[u8]) -> String {
    let mut hex = String::with_capacity(digest.len() * 2);
    for byte in digest {
        hex.push_str(&format!("{byte:02x}"));
    }
    hex
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn matches_known_sha256_vectors() {
        assert_eq!(
            hash_bytes(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            hash_bytes(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn streams_a_file_larger_than_one_chunk() {
        let directory = std::env::temp_dir().join(format!(
            "voanisa-hash-{}",
            std::process::id()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("payload.bin");

        let mut bytes = vec![0u8; (1 << 20) + 123];
        for (index, byte) in bytes.iter_mut().enumerate() {
            *byte = (index % 251) as u8;
        }
        let mut file = File::create(&path).unwrap();
        file.write_all(&bytes).unwrap();
        drop(file);

        assert_eq!(hash_file(&path).unwrap(), hash_bytes(&bytes));
        std::fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn reports_missing_files() {
        let path = std::env::temp_dir().join("voanisa-missing-file");
        assert!(hash_file(&path).is_err());
    }
}
