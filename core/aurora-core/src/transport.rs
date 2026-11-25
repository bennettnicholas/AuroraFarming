//! Bridges CoreBluetooth (Swift) to open_oura's [`Transport`] trait.
//!
//! The Swift side owns the BLE connection. It implements [`RingLink`] so Rust can
//! write request frames to the ring's write characteristic, and it forwards every
//! notification it receives into [`FfiTransport::push`]. open_oura's `OuraClient`
//! then runs the whole protocol (auth, setup, history drain) on top of this pipe,
//! so the app speaks exactly the protocol the reference implementation verified.

use std::sync::Arc;

use async_trait::async_trait;
use oura_link::transport::Transport;
use tokio::sync::broadcast;

/// Implemented in Swift by the CoreBluetooth peripheral wrapper.
#[uniffi::export(callback_interface)]
pub trait RingLink: Send + Sync {
    /// Queue `data` for the ring's write characteristic (`98ed0002-…`).
    /// Return `false` when the link is down so the request fails fast instead of
    /// waiting out a quiet window.
    fn write(&self, data: Vec<u8>) -> bool;
}

/// A [`Transport`] whose writes go to Swift and whose notifications come from Swift.
pub struct FfiTransport {
    link: Arc<dyn RingLink>,
    tx: broadcast::Sender<Vec<u8>>,
}

impl FfiTransport {
    pub fn new(link: Box<dyn RingLink>) -> Self {
        // History drains can burst hundreds of notifications between polls.
        let (tx, _) = broadcast::channel(4096);
        Self {
            link: Arc::from(link),
            tx,
        }
    }

    /// Feed one inbound BLE notification (raw bytes) to whoever is listening.
    pub fn push(&self, frame: Vec<u8>) {
        // No receivers simply means no request is in flight: dropping is correct.
        let _ = self.tx.send(frame);
    }
}

#[async_trait]
impl Transport for FfiTransport {
    async fn write(&self, data: &[u8]) -> oura_link::Result<()> {
        if self.link.write(data.to_vec()) {
            Ok(())
        } else {
            Err(oura_link::Error::Ble("ring is not connected".into()))
        }
    }

    fn subscribe(&self) -> broadcast::Receiver<Vec<u8>> {
        self.tx.subscribe()
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::sync::Mutex;

    /// A scripted ring for tests: replies to known request hex with canned frames,
    /// delivered through the same `push` path Swift uses.
    pub struct ScriptedRing {
        pub replies: Mutex<HashMap<String, Vec<Vec<u8>>>>,
        pub writes: Mutex<Vec<String>>,
        pub sink: Mutex<Option<Arc<crate::session::RingSession>>>,
    }

    impl ScriptedRing {
        pub fn new() -> Arc<Self> {
            Arc::new(Self {
                replies: Mutex::new(HashMap::new()),
                writes: Mutex::new(Vec::new()),
                sink: Mutex::new(None),
            })
        }
        pub fn on(&self, req: &str, frames: &[&str]) {
            self.replies.lock().unwrap().insert(
                req.to_string(),
                frames.iter().map(|f| hex::decode(f).unwrap()).collect(),
            );
        }
    }

    pub struct ScriptedLink(pub Arc<ScriptedRing>);

    impl RingLink for ScriptedLink {
        fn write(&self, data: Vec<u8>) -> bool {
            let key = hex::encode(&data);
            self.0.writes.lock().unwrap().push(key.clone());
            let frames = self.0.replies.lock().unwrap().get(&key).cloned();
            let sink = self.0.sink.lock().unwrap().clone();
            if let (Some(frames), Some(sink)) = (frames, sink) {
                // Reply asynchronously, like a real radio would.
                tokio::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
                    for f in frames {
                        sink.push_notification(f);
                    }
                });
            }
            true
        }
    }
}
