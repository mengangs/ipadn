//! On-device pairing (iOS 27 and later).
//!
//! iPadn presents itself as a computer the device can pair with. The app
//! advertises `_remotepairing-pairable-host._tcp` with the TXT records this
//! module hands back; the user picks iPadn in Settings › Privacy & Security ›
//! Developer Mode and types the code shown. The device then connects here and
//! runs the pairing, which yields the same remote pairing file a computer
//! would create.

use std::ffi::{CString, c_char, c_void};
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine as _;
use idevice::remote_pairing::{PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket};
use serde::Deserialize;
use serde_json::{Value as Json, json};
use tokio::net::TcpListener;
use tokio::sync::Notify;

use crate::{Failure, fail, failure};

pub const EVENT_READY: i32 = 0;
pub const EVENT_CONNECTED: i32 = 1;
pub const EVENT_PIN: i32 = 2;

/// How long iPadn waits for the user to finish in Settings.
const PAIRING_TIMEOUT: Duration = Duration::from_secs(300);
/// Settings shows this as the computer's model; iOS only pairs with computers.
const HOST_MODEL: &str = "Mac17,7";

pub type EventCallback = extern "C" fn(context: *mut c_void, kind: i32, payload: *const c_char);

#[derive(Clone, Copy)]
pub struct Events {
    pub callback: Option<EventCallback>,
    pub context: *mut c_void,
}
// The caller guarantees `context` outlives the call and may be used from any thread.
unsafe impl Send for Events {}
unsafe impl Sync for Events {}

impl Events {
    fn send(&self, kind: i32, payload: &str) {
        if let (Some(callback), Ok(text)) = (self.callback, CString::new(payload)) {
            callback(self.context, kind, text.as_ptr());
        }
    }
}

#[derive(Deserialize)]
pub struct PairRequest {
    /// The name Settings shows, e.g. "iPadn".
    pub name: String,
}

/// The pairing in progress, so another thread can stop it.
static CURRENT: Mutex<Option<Arc<Notify>>> = Mutex::new(None);

pub fn cancel() {
    if let Some(stop) = CURRENT.lock().ok().and_then(|current| current.clone()) {
        // Stores a permit when nothing waits yet, so an early cancel is kept.
        stop.notify_one();
    }
}

/// Listens on both address families on one port: the device may reach this
/// app over IPv4 or IPv6 loopback depending on how it resolved the service.
async fn listen() -> Result<(Option<TcpListener>, Option<TcpListener>, u16), Failure> {
    let v6 = TcpListener::bind(SocketAddr::from((Ipv6Addr::UNSPECIFIED, 0))).await.ok();
    let port = match &v6 {
        Some(listener) => listener.local_addr().map_err(fail("listen"))?.port(),
        None => 0,
    };
    let v4 = TcpListener::bind(SocketAddr::from((Ipv4Addr::UNSPECIFIED, port))).await.ok();
    let port = match (&v6, &v4) {
        (Some(_), _) => port,
        (None, Some(listener)) => listener.local_addr().map_err(fail("listen"))?.port(),
        (None, None) => return Err(failure("listen", "no address to listen on")),
    };
    Ok((v6, v4, port))
}

async fn accept_one(listener: &Option<TcpListener>) -> std::io::Result<tokio::net::TcpStream> {
    match listener {
        Some(listener) => listener.accept().await.map(|(stream, _)| stream),
        None => std::future::pending().await,
    }
}

pub async fn pair(request: PairRequest, events: Events) -> Result<Json, Failure> {
    let stop = Arc::new(Notify::new());
    *CURRENT.lock().map_err(fail("pairing"))? = Some(stop.clone());

    let (v6, v4, port) = listen().await?;
    let mut pairing = RpPairingFile::generate(&request.name);
    let host = PairableHostInfo::generate(&request.name, HOST_MODEL);
    // The service instance name must be the identifier sent during pairing.
    let identifier = pairing.identifier.clone();
    let txt: serde_json::Map<String, Json> = host
        .mdns_txt_records(&identifier)
        .into_iter()
        .map(|(key, value)| (key, Json::String(value)))
        .collect();
    events.send(EVENT_READY, &json!({ "port": port, "identifier": identifier, "txt": txt }).to_string());

    let work = async {
        let stream = tokio::select! {
            accepted = accept_one(&v6) => accepted,
            accepted = accept_one(&v4) => accepted,
        }
        .map_err(fail("accept"))?;
        events.send(EVENT_CONNECTED, "");
        let mut responder = PairableHost::new(RpPairingSocket::new_device(stream), host);
        responder
            .accept(&mut pairing, |pin| async move { events.send(EVENT_PIN, &pin) })
            .await
            .map_err(fail("pairing"))
    };
    let outcome = tokio::select! {
        biased;
        _ = stop.notified() => Err(failure("cancelled", "cancelled")),
        _ = tokio::time::sleep(PAIRING_TIMEOUT) => Err(failure("timeout", "timed out")),
        result = work => result,
    };
    if let Ok(mut current) = CURRENT.lock() {
        *current = None;
    }
    let device = outcome?;

    Ok(json!({
        "ok": true,
        "device_name": device.name,
        "pairing_file": base64::engine::general_purpose::STANDARD.encode(pairing.to_bytes()),
    }))
}
