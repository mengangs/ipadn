//! Native installation for iPadn.
//!
//! Talks to this device's own installation service, the one desktop tools
//! reach over USB, through a loopback VPN and a remote pairing file. Unlike a
//! manifest (`itms-services`) install, the system keeps the package's App
//! Store purchase record and replaces an App Store copy in place.
//!
//! On iOS 27 and later the pairing file itself can be made on the device; see
//! [`pairing`].
//!
//! Every entry point takes a JSON request and returns a JSON reply the caller
//! frees with `iPadnNativeFree`; nothing here aborts or unwinds into Swift.

use std::ffi::{CStr, CString, c_char, c_void};
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use idevice::afc::{AfcClient, opcode::AfcFopenMode};
use idevice::installation_proxy::InstallationProxyClient;
use idevice::remote_pairing::{
    RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native,
};
use idevice::rsd::RsdHandshake;
use idevice::tcp::{adapter::Adapter, handle::AdapterHandle};
use idevice::{IdeviceError, RsdService};
use serde::Deserialize;
use serde_json::{Value as Json, json};
use tokio::io::AsyncReadExt;

mod pairing;

const STAGING_DIRECTORY: &str = "PublicStaging";
const STAGED_PACKAGE: &str = "PublicStaging/ipadn-native.ipa";
const UPLOAD_CHUNK: usize = 1024 * 1024;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(12);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(30);
const LOOKUP_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_REPLY: u32 = 64 * 1024 * 1024;

pub const PHASE_CONNECT: i32 = 0;
pub const PHASE_UPLOAD: i32 = 1;
pub const PHASE_INSTALL: i32 = 2;

static CANCELLED: AtomicBool = AtomicBool::new(false);

pub type ProgressCallback = extern "C" fn(context: *mut c_void, phase: i32, done: u64, total: u64);

#[derive(Clone, Copy)]
struct Progress {
    callback: Option<ProgressCallback>,
    context: *mut c_void,
}
// The caller guarantees `context` outlives the call and may be used from any thread.
unsafe impl Send for Progress {}
unsafe impl Sync for Progress {}

impl Progress {
    fn report(&self, phase: i32, done: u64, total: u64) {
        if let Some(callback) = self.callback {
            callback(self.context, phase, done, total);
        }
    }
}

#[derive(Deserialize)]
pub(crate) struct Request {
    /// Path of the remote pairing (RPPairing) file.
    pairing_file: String,
    /// Address of this device through the loopback VPN, normally 10.7.0.1.
    host: String,
    /// Port of `_remotepairing._tcp`, discovered by the caller.
    port: u16,
    bundle_id: String,
    #[serde(default)]
    ipa: Option<String>,
    #[serde(default)]
    hostname: Option<String>,
    /// A replacement purchase record (iTunesMetadata.plist, base64). The
    /// system keeps it instead of the package's own; iPadn uses it to mark
    /// the installed version as the newest so the App Store offers no update.
    #[serde(default)]
    metadata: Option<String>,
}

/// A failure tagged with the step it happened in, so the app can explain it.
pub(crate) struct Failure {
    stage: &'static str,
    message: String,
}

pub(crate) fn fail<E: std::fmt::Debug>(stage: &'static str) -> impl FnOnce(E) -> Failure {
    move |error| Failure { stage, message: format!("{error:?}") }
}

pub(crate) fn failure(stage: &'static str, message: impl Into<String>) -> Failure {
    Failure { stage, message: message.into() }
}

struct Session {
    adapter: AdapterHandle,
    handshake: RsdHandshake,
}

async fn connect(request: &Request) -> Result<Session, Failure> {
    let ip: IpAddr = request.host.parse().map_err(fail("request"))?;
    let address = SocketAddr::new(ip, request.port);
    let mut pairing = RpPairingFile::read_from_file(&request.pairing_file)
        .await
        .map_err(fail("pairing_file"))?;
    let hostname = request.hostname.as_deref().unwrap_or("iPadn");

    let stream = tokio::time::timeout(CONNECT_TIMEOUT, tokio::net::TcpStream::connect(address))
        .await
        .map_err(|_| failure("connect", "timed out"))?
        .map_err(fail("connect"))?;
    let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), hostname);

    // Verify only. A rejected file must not start a new pairing: that would
    // raise a trust prompt and silently replace the user's file.
    tokio::time::timeout(HANDSHAKE_TIMEOUT, async {
        client.attempt_pair_verify().await?;
        client.validate_pairing(&mut pairing).await
    })
    .await
    .map_err(|_| failure("pairing", "timed out"))?
    .map_err(fail("pairing"))?;

    tokio::time::timeout(HANDSHAKE_TIMEOUT, open_tunnel(&mut client, address))
        .await
        .map_err(|_| failure("tunnel", "timed out"))?
        .map_err(fail("tunnel"))
}

async fn open_tunnel(
    client: &mut RemotePairingClient<RpPairingSocket<tokio::net::TcpStream>>,
    mut address: SocketAddr,
) -> Result<Session, IdeviceError> {
    address.set_port(client.create_tcp_listener().await?);
    let stream = tokio::net::TcpStream::connect(address).await?;
    let tunnel = connect_tls_psk_tunnel_native(stream, client.encryption_key()).await?;

    let invalid = |what: &str| IdeviceError::InternalError(format!("invalid tunnel {what}"));
    let client_ip: IpAddr =
        tunnel.info.client_address.parse().map_err(|_| invalid("client address"))?;
    let server_ip: IpAddr =
        tunnel.info.server_address.parse().map_err(|_| invalid("server address"))?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;

    let mut adapter = Adapter::new(Box::new(tunnel.into_inner()), client_ip, server_ip);
    adapter.set_mss(mtu.clamp(576, 8192) - 60);
    let mut adapter = adapter.to_async_handle();
    let handshake = RsdHandshake::new(adapter.connect(rsd_port).await?).await?;
    Ok(Session { adapter, handshake })
}

/// installation_proxy frames each plist with a big-endian length. The crate
/// keeps its plist helpers private and its lookup cannot ask for attributes.
async fn exchange(
    client: &mut InstallationProxyClient,
    message: &plist::Value,
) -> Result<plist::Dictionary, IdeviceError> {
    let mut body = Vec::new();
    plist::to_writer_xml(&mut body, message)
        .map_err(|error| IdeviceError::InternalError(error.to_string()))?;
    let mut frame = (body.len() as u32).to_be_bytes().to_vec();
    frame.extend(body);
    client.idevice.send_raw(&frame).await?;

    let header = client.idevice.read_raw(4).await?;
    let length = u32::from_be_bytes([header[0], header[1], header[2], header[3]]);
    if length > MAX_REPLY {
        return Err(IdeviceError::UnexpectedResponse("oversized reply".into()));
    }
    let reply = client.idevice.read_raw(length as usize).await?;
    plist::from_bytes(&reply).map_err(|error| IdeviceError::UnexpectedResponse(error.to_string()))
}

async fn lookup(session: &mut Session, bundle_id: &str) -> Result<Json, IdeviceError> {
    let mut client =
        InstallationProxyClient::connect_rsd(&mut session.adapter, &mut session.handshake).await?;
    let attributes = [
        "CFBundleIdentifier",
        "CFBundleShortVersionString",
        "CFBundleVersion",
        "SignerIdentity",
        "IsPlaceholder",
        "iTunesMetadata",
    ];
    let mut options = plist::Dictionary::new();
    options.insert("ApplicationType".into(), "Any".into());
    options.insert("BundleIDs".into(), plist::Value::Array(vec![bundle_id.into()]));
    options.insert(
        "ReturnAttributes".into(),
        plist::Value::Array(attributes.into_iter().map(Into::into).collect()),
    );
    let mut message = plist::Dictionary::new();
    message.insert("Command".into(), "Lookup".into());
    message.insert("ClientOptions".into(), plist::Value::Dictionary(options));

    let mut reply = exchange(&mut client, &plist::Value::Dictionary(message)).await?;
    if let Some(error) = reply.get("Error").and_then(|value| value.as_string()) {
        return Err(IdeviceError::UnexpectedResponse(error.to_string()));
    }
    // An unreadable inventory must never be reported as "not installed".
    let Some(plist::Value::Dictionary(mut result)) = reply.remove("LookupResult") else {
        return Err(IdeviceError::UnexpectedResponse("missing LookupResult".into()));
    };
    let Some(plist::Value::Dictionary(app)) = result.remove(bundle_id) else {
        return Ok(json!({ "installed": false }));
    };
    Ok(describe(&app))
}

/// What iPadn reports about one installed app.
fn describe(app: &plist::Dictionary) -> Json {
    let text = |key: &str| app.get(key).and_then(|value| value.as_string()).map(str::to_string);
    let metadata = match app.get("iTunesMetadata") {
        Some(plist::Value::Data(data)) => plist::from_bytes::<plist::Dictionary>(data).ok(),
        Some(plist::Value::Dictionary(dictionary)) => Some(dictionary.clone()),
        _ => None,
    }
    .unwrap_or_default();
    let number = |key: &str| {
        metadata.get(key).and_then(|value| {
            value
                .as_unsigned_integer()
                .map(|number| number.to_string())
                .or_else(|| value.as_signed_integer().map(|number| number.to_string()))
                .or_else(|| value.as_string().map(str::to_string))
        })
    };
    json!({
        "installed": true,
        "bundle_id": text("CFBundleIdentifier"),
        "name": text("CFBundleDisplayName").or_else(|| text("CFBundleName")),
        "version": text("CFBundleShortVersionString"),
        "build": text("CFBundleVersion"),
        "signer": text("SignerIdentity"),
        "placeholder": app.get("IsPlaceholder").and_then(|value| value.as_boolean()).unwrap_or(false),
        "store_item_id": number("itemId"),
        "store_version_id": number("softwareVersionExternalIdentifier"),
        "has_purchase_record": metadata.contains_key("com.apple.iTunesStore.downloadInfo"),
        "manifest_install": metadata.contains_key("enterpriseInstallURL"),
    })
}

/// Every app the user installed, with the same details as `lookup`.
async fn list(session: &mut Session) -> Result<Json, IdeviceError> {
    let mut client =
        InstallationProxyClient::connect_rsd(&mut session.adapter, &mut session.handshake).await?;
    let attributes = [
        "CFBundleIdentifier",
        "CFBundleDisplayName",
        "CFBundleName",
        "CFBundleShortVersionString",
        "CFBundleVersion",
        "SignerIdentity",
        "IsPlaceholder",
        "iTunesMetadata",
    ];
    let mut options = plist::Dictionary::new();
    options.insert("ApplicationType".into(), "User".into());
    options.insert(
        "ReturnAttributes".into(),
        plist::Value::Array(attributes.into_iter().map(Into::into).collect()),
    );
    let mut message = plist::Dictionary::new();
    message.insert("Command".into(), "Lookup".into());
    message.insert("ClientOptions".into(), plist::Value::Dictionary(options));

    let mut reply = exchange(&mut client, &plist::Value::Dictionary(message)).await?;
    if let Some(error) = reply.get("Error").and_then(|value| value.as_string()) {
        return Err(IdeviceError::UnexpectedResponse(error.to_string()));
    }
    let Some(plist::Value::Dictionary(result)) = reply.remove("LookupResult") else {
        return Err(IdeviceError::UnexpectedResponse("missing LookupResult".into()));
    };
    let apps: Vec<Json> = result
        .iter()
        .filter_map(|(bundle_id, value)| {
            let plist::Value::Dictionary(app) = value else { return None };
            let mut entry = describe(app);
            if entry["bundle_id"].is_null() {
                entry["bundle_id"] = json!(bundle_id);
            }
            Some(entry)
        })
        .collect();
    Ok(json!(apps))
}

async fn upload(session: &mut Session, path: &str, progress: Progress) -> Result<(), Failure> {
    let mut file = tokio::fs::File::open(path).await.map_err(fail("package"))?;
    let total = file.metadata().await.map_err(fail("package"))?.len();
    let mut afc = AfcClient::connect_rsd(&mut session.adapter, &mut session.handshake)
        .await
        .map_err(fail("upload"))?;
    if afc.get_file_info(STAGING_DIRECTORY).await.is_err() {
        afc.mk_dir(STAGING_DIRECTORY).await.map_err(fail("upload"))?;
    }

    let mut buffer = vec![0u8; UPLOAD_CHUNK];
    let mut sent = 0u64;
    progress.report(PHASE_UPLOAD, 0, total);
    let (outcome, closed) = {
        let mut descriptor =
            afc.open(STAGED_PACKAGE, AfcFopenMode::WrOnly).await.map_err(fail("upload"))?;
        // Streamed in chunks: reading a whole package into memory gets a phone
        // app killed for packages of a few hundred megabytes.
        let outcome: Result<(), Failure> = loop {
            if CANCELLED.load(Ordering::SeqCst) {
                break Err(failure("cancelled", "cancelled"));
            }
            let read = match file.read(&mut buffer).await {
                Ok(0) => break Ok(()),
                Ok(read) => read,
                Err(error) => break Err(fail("package")(error)),
            };
            if let Err(error) = descriptor.write_entire(&buffer[..read]).await {
                break Err(fail("upload")(error));
            }
            sent += read as u64;
            progress.report(PHASE_UPLOAD, sent, total);
        };
        // Close even after a failed write, or the device-side descriptor leaks.
        (outcome, descriptor.close().await.map_err(fail("upload")))
    };
    let complete = outcome.is_ok() && closed.is_ok() && sent == total;
    if !complete {
        let _ = afc.remove(STAGED_PACKAGE).await;
    }
    outcome?;
    closed?;
    if sent != total {
        return Err(failure("package", "package changed while uploading"));
    }
    Ok(())
}

async fn remove_staged(session: &mut Session) {
    if let Ok(mut afc) = AfcClient::connect_rsd(&mut session.adapter, &mut session.handshake).await
    {
        let _ = afc.remove(STAGED_PACKAGE).await;
    }
}

async fn checked_lookup(session: &mut Session, bundle_id: &str) -> Result<Json, Failure> {
    tokio::time::timeout(LOOKUP_TIMEOUT, lookup(session, bundle_id))
        .await
        .map_err(|_| failure("lookup", "timed out"))?
        .map_err(fail("lookup"))
}

async fn checked_list(session: &mut Session) -> Result<Json, Failure> {
    tokio::time::timeout(LOOKUP_TIMEOUT, list(session))
        .await
        .map_err(|_| failure("list", "timed out"))?
        .map_err(fail("list"))
}

async fn install(request: &Request, progress: Progress) -> Result<Json, Failure> {
    let package = request.ipa.as_deref().ok_or_else(|| failure("request", "missing ipa"))?;
    progress.report(PHASE_CONNECT, 0, 1);
    let mut session = connect(request).await?;
    let before = checked_lookup(&mut session, &request.bundle_id).await?;
    progress.report(PHASE_CONNECT, 1, 1);

    upload(&mut session, package, progress).await?;
    if CANCELLED.load(Ordering::SeqCst) {
        remove_staged(&mut session).await;
        return Err(failure("cancelled", "cancelled"));
    }

    // Upgrade replaces an installed copy in place and keeps its data; the
    // system reads the purchase record and licence from the package itself.
    let upgrade = before["installed"] == json!(true);
    let mut options = plist::Dictionary::new();
    options.insert("CFBundleIdentifier".into(), request.bundle_id.clone().into());
    if let Some(encoded) = request.metadata.as_deref() {
        use base64::Engine;
        let record = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(fail("request"))?;
        options.insert("iTunesMetadata".into(), plist::Value::Data(record));
    }
    let options = Some(plist::Value::Dictionary(options));
    let mut client =
        InstallationProxyClient::connect_rsd(&mut session.adapter, &mut session.handshake)
            .await
            .map_err(fail("install"))?;
    progress.report(PHASE_INSTALL, 0, 100);
    let report = |(percent, progress): (u64, Progress)| async move {
        progress.report(PHASE_INSTALL, percent.min(100), 100);
    };
    let result = if upgrade {
        client.upgrade_with_callback(STAGED_PACKAGE, options, report, progress).await
    } else {
        client.install_with_callback(STAGED_PACKAGE, options, report, progress).await
    };
    if let Err(error) = result {
        remove_staged(&mut session).await;
        return Err(fail("install")(error));
    }

    let after = checked_lookup(&mut session, &request.bundle_id).await.ok();
    Ok(json!({ "ok": true, "upgraded": upgrade, "before": before, "after": after }))
}

fn run<R, F, Fut>(request: *const c_char, work: F) -> *mut c_char
where
    R: serde::de::DeserializeOwned,
    F: FnOnce(R) -> Fut,
    Fut: std::future::Future<Output = Result<Json, Failure>>,
{
    let reply = (|| {
        if request.is_null() {
            return Err(failure("request", "null request"));
        }
        let text = unsafe { CStr::from_ptr(request) }.to_str().map_err(fail("request"))?;
        let request: R = serde_json::from_str(text).map_err(fail("request"))?;
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(fail("runtime"))?;
        let reply = runtime.block_on(work(request));
        // Tunnel tasks hold sockets; do not wait on them indefinitely.
        runtime.shutdown_timeout(Duration::from_secs(2));
        reply
    })();
    let reply = reply.unwrap_or_else(|failure| {
        json!({ "ok": false, "stage": failure.stage, "message": failure.message })
    });
    CString::new(reply.to_string())
        .unwrap_or_else(|_| {
            CString::new(r#"{"ok":false,"stage":"reply","message":"invalid reply"}"#).unwrap()
        })
        .into_raw()
}

/// Installs or upgrades `ipa`. Blocks until the system finishes.
///
/// # Safety
/// `request` must be a valid NUL-terminated string. `context` must stay valid
/// for the whole call; `progress` may be invoked from another thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iPadnNativeInstall(
    request: *const c_char,
    progress: Option<ProgressCallback>,
    context: *mut c_void,
) -> *mut c_char {
    CANCELLED.store(false, Ordering::SeqCst);
    let progress = Progress { callback: progress, context };
    run(request, |request: Request| async move { install(&request, progress).await })
}

/// Connects and reports what the system has installed for `bundle_id`.
///
/// # Safety
/// `request` must be a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iPadnNativeLookup(request: *const c_char) -> *mut c_char {
    run(request, |request: Request| async move {
        let mut session = connect(&request).await?;
        let app = checked_lookup(&mut session, &request.bundle_id).await?;
        Ok(json!({ "ok": true, "app": app }))
    })
}

/// Connects and reports every app the user installed.
///
/// # Safety
/// `request` must be a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iPadnNativeList(request: *const c_char) -> *mut c_char {
    run(request, |request: Request| async move {
        let mut session = connect(&request).await?;
        let apps = checked_list(&mut session).await?;
        Ok(json!({ "ok": true, "apps": apps }))
    })
}

/// Lets the device pair with this app as if it were a computer (iOS 27 and
/// later). Blocks until pairing completes, fails, times out or is cancelled.
///
/// `events` receives, in order: ready (JSON with the port, the service
/// identifier and the TXT records to advertise), connected, and the PIN the
/// user types on the device. The reply carries the pairing file as base64.
///
/// # Safety
/// `request` must be a valid NUL-terminated string. `context` must stay valid
/// for the whole call; `events` may be invoked from another thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iPadnNativePair(
    request: *const c_char,
    events: Option<pairing::EventCallback>,
    context: *mut c_void,
) -> *mut c_char {
    let events = pairing::Events { callback: events, context };
    run(request, |request: pairing::PairRequest| async move { pairing::pair(request, events).await })
}

/// Stops a pairing that is waiting for the device.
#[unsafe(no_mangle)]
pub extern "C" fn iPadnNativePairCancel() {
    pairing::cancel();
}

/// Stops an upload in progress. A started system install cannot be stopped.
#[unsafe(no_mangle)]
pub extern "C" fn iPadnNativeCancel() {
    CANCELLED.store(true, Ordering::SeqCst);
}

/// Frees a reply returned by this library.
///
/// # Safety
/// `reply` must come from this library and not have been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn iPadnNativeFree(reply: *mut c_char) {
    if !reply.is_null() {
        drop(unsafe { CString::from_raw(reply) });
    }
}
