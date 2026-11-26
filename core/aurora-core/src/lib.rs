//! `aurora-core`: the Rust half of the Aurora iOS app.
//!
//! * [`session`]: one connected ring. Runs open_oura's `OuraClient` (auth, Ring 5
//!   stream setup, time sync, history drain) over a CoreBluetooth pipe supplied by
//!   Swift ([`transport`]).
//! * [`store`]: the on-phone SQLite database. Raw ring events are kept lossless in
//!   open_oura's `oura-store` schema; [`metrics`] turns them into dated, typed
//!   samples (heart rate, HRV, temperature, SpO2, ...) that the UI charts and that
//!   export connectors (Nocturne, Trio, ...) read.
//!
//! Everything is exported to Swift with UniFFI. Nothing here touches the network.

uniffi::setup_scaffolding!();

pub mod metrics;
pub(crate) mod ring_time;
pub mod session;
pub mod store;
pub mod transport;

/// Errors surfaced to Swift.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    /// Bluetooth link problems (not connected, write refused, link lost mid-batch).
    #[error("{message}")]
    Link { message: String },
    /// The ring rejected the auth key, or has no key installed yet.
    #[error("{message}")]
    Auth { message: String },
    /// The ring answered something unexpected.
    #[error("{message}")]
    Ring { message: String },
    /// The local database failed.
    #[error("{message}")]
    Store { message: String },
    /// An auth key that is not 32 hex characters.
    #[error("the auth key must be 32 hex characters (16 bytes)")]
    InvalidKey,
}

impl From<oura_link::Error> for CoreError {
    fn from(e: oura_link::Error) -> Self {
        use oura_link::Error as E;
        let message = e.to_string();
        match e {
            E::Auth(_) => CoreError::Auth { message },
            E::Protocol(_) => CoreError::Ring { message },
            _ => CoreError::Link { message },
        }
    }
}

impl From<oura_store::Error> for CoreError {
    fn from(e: oura_store::Error) -> Self {
        CoreError::Store {
            message: e.to_string(),
        }
    }
}

impl From<rusqlite::Error> for CoreError {
    fn from(e: rusqlite::Error) -> Self {
        CoreError::Store {
            message: e.to_string(),
        }
    }
}

/// Version string, also a cheap check that the FFI round-trip works.
#[uniffi::export]
pub fn core_version() -> String {
    format!("aurora-core {}", env!("CARGO_PKG_VERSION"))
}

/// Mint a fresh random 16-byte ring auth key, as 32 lowercase hex characters.
/// Used when pairing a factory-reset ring. Store the result in the Keychain
/// *before* installing it on the ring.
#[uniffi::export]
pub fn generate_auth_key() -> Result<String, CoreError> {
    let mut key = [0u8; 16];
    getrandom::getrandom(&mut key).map_err(|e| CoreError::Store {
        message: format!("no system randomness: {e}"),
    })?;
    Ok(hex::encode(key))
}

/// Whether `hex_key` is a well-formed auth key (32 hex characters, spaces/colons ignored).
#[uniffi::export]
pub fn is_valid_auth_key(hex_key: String) -> bool {
    parse_key(&hex_key).is_ok()
}

pub(crate) fn parse_key(hex_key: &str) -> Result<[u8; 16], CoreError> {
    let cleaned: String = hex_key
        .chars()
        .filter(|c| !c.is_whitespace() && *c != ':' && *c != '-')
        .collect();
    let bytes = hex::decode(cleaned).map_err(|_| CoreError::InvalidKey)?;
    bytes.try_into().map_err(|_| CoreError::InvalidKey)
}

/// Human-readable name of a ring history-event tag (e.g. `0x5d` → `hrv_event`).
#[uniffi::export]
pub fn event_name(tag: u8) -> String {
    oura_protocol::events::event_name(tag).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_round_trip() {
        let k = generate_auth_key().unwrap();
        assert_eq!(k.len(), 32);
        assert!(is_valid_auth_key(k.clone()));
        assert!(is_valid_auth_key("44:31:96:7d:8b:ac:c2:65:97:43:14:2b:68:39:1d:9a".into()));
        assert!(!is_valid_auth_key("abc".into()));
        assert_ne!(k, generate_auth_key().unwrap());
    }
}
