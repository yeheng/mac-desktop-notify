use serde_json::Value;
use std::sync::{
    mpsc::{self, Receiver, SyncSender, TrySendError},
    Arc, Mutex,
};

#[derive(Clone, Default)]
pub(crate) struct EventHub(Arc<Mutex<Vec<SyncSender<Value>>>>);
impl EventHub {
    pub fn subscribe(&self) -> Receiver<Value> {
        let (sender, receiver) = mpsc::sync_channel(64);
        self.0.lock().unwrap().push(sender);
        receiver
    }
    pub fn broadcast(&self, event: Value) {
        self.0
            .lock()
            .unwrap()
            .retain(|sender| match sender.try_send(event.clone()) {
                Ok(()) => true,
                Err(TrySendError::Full(_) | TrySendError::Disconnected(_)) => false,
            });
    }
}
