// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

//! Apple ID sign-in for the signing refresh (app/Madeira/AppleSignIn.swift), for
//! a copy no installer left a sign-in for.
//!
//! The sign-in is isideload's (MIT, nab138/isideload), the library SideInstaller
//! and iloader sign in with: Apple's GrandSlam SRP exchange, in which the
//! password never leaves the device, the second factor, and the
//! `com.apple.gs.xcode.auth` token the developer portal takes. This file only
//! bridges it to Swift: it asks Swift for the second factor and returns the
//! token, the anisette identity it was issued to and the account's teams.
//! Nothing is written to disk, nothing is logged and the password is not kept.

use std::ffi::{CStr, CString, c_char, c_void};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine;
use base64::prelude::BASE64_STANDARD;
use isideload::SideloadError;
use isideload::anisette::AnisetteDataGenerator;
use isideload::anisette::remote_v3::RemoteV3AnisetteProvider;
use isideload::auth::apple_account::{AppToken, AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse};
use isideload::dev::developer_session::DeveloperSession;
use isideload::dev::teams::{DeveloperTeam, TeamsApi};
use isideload::util::storage::InMemoryStorage;
use rootcause::Report;
use serde_json::{Value, json};
use tokio::sync::RwLock;

use crate::set_error;

/// Asks the user for the second factor. `request` is JSON (see `request_json`);
/// the answer, JSON too (see `answer`), goes NUL-terminated into `reply`, which
/// holds `reply_capacity` bytes. Returns 1 when it wrote one, 0 to give up the
/// sign-in. Called on the thread that called `madeira_apple_sign_in`, and may
/// block for as long as the user takes.
pub type MadeiraAppleTwoFactorCallback =
    Option<extern "C" fn(context: *mut c_void, request: *const c_char, reply: *mut c_char, reply_capacity: usize) -> i32>;

/// How long Apple's address book and the anisette server get to answer.
const SETUP_TIMEOUT: Duration = Duration::from_secs(40);

struct TwoFactor {
    callback: MadeiraAppleTwoFactorCallback,
    context: *mut c_void,
    /// The user gave up: the sign-in then fails, and this says why.
    cancelled: Arc<AtomicBool>,
}
// The context is only handed back to the caller's callback, on the calling thread.
unsafe impl Send for TwoFactor {}
unsafe impl Sync for TwoFactor {}

impl TwoFactor {
    fn ask(&self, params: &TwoFactorCallbackParams) -> TwoFactorCallbackResponse {
        let mut reply = vec![0u8; 512];
        let answered = match (self.callback, CString::new(request_json(params))) {
            (Some(callback), Ok(request)) => {
                callback(self.context, request.as_ptr(), reply.as_mut_ptr().cast(), reply.len()) != 0
            }
            _ => false,
        };
        let end = reply.iter().position(|&b| b == 0).unwrap_or(reply.len());
        let response = if answered { answer(&reply[..end]) } else { TwoFactorCallbackResponse::Abort };
        if matches!(response, TwoFactorCallbackResponse::Abort) {
            self.cancelled.store(true, Ordering::SeqCst);
        }
        response
    }
}

/// What the sign-in waits for, for Swift: `method` is `device` (a code went to the
/// account's trusted devices), `sms` (one was texted to `selectedNumberId`) or
/// `choose` (the last way failed and no code is on its way).
fn request_json(params: &TwoFactorCallbackParams) -> String {
    let method = if params.unknown {
        "choose"
    } else if params.sms {
        "sms"
    } else {
        "device"
    };
    json!({
        "method": method,
        "selectedNumberId": params.selected_number_id,
        "lastError": params.last_error,
        // Masked by Apple, as in "+39 ••• ••• ••89".
        "numbers": params.numbers.iter().map(|number| json!({
            "id": number.id,
            "number": number.number_with_dial_code,
            "pushMode": number.push_mode,
        })).collect::<Vec<_>>(),
    })
    .to_string()
}

/// The user's answer: `{"action":"code","code":"123456"}`, `{"action":"sms","id":1}`,
/// `{"action":"devices"}` or `{"action":"resend"}`. Anything else gives up.
fn answer(reply: &[u8]) -> TwoFactorCallbackResponse {
    let Ok(reply) = serde_json::from_slice::<Value>(reply) else {
        return TwoFactorCallbackResponse::Abort;
    };
    match reply["action"].as_str() {
        Some("code") => match reply["code"].as_str().map(str::trim) {
            Some(code) if !code.is_empty() => TwoFactorCallbackResponse::SubmitCode(code.to_string()),
            _ => TwoFactorCallbackResponse::Abort,
        },
        Some("sms") => match reply["id"].as_u64().and_then(|id| u32::try_from(id).ok()) {
            Some(id) => TwoFactorCallbackResponse::SendSms(id),
            None => TwoFactorCallbackResponse::Abort,
        },
        Some("devices") => TwoFactorCallbackResponse::SendToDevices,
        Some("resend") => TwoFactorCallbackResponse::ResendCode,
        _ => TwoFactorCallbackResponse::Abort,
    }
}

/// Why a sign-in did not happen, as `madeira_apple_sign_in` returns it.
#[derive(Debug)]
enum SignInFailure {
    /// The user closed the second-factor prompt.
    Cancelled,
    /// The anisette server gave nothing Apple takes: another one may.
    Anisette(String),
    Other(String),
}

impl SignInFailure {
    fn code(&self) -> i32 {
        match self {
            SignInFailure::Cancelled => 1,
            SignInFailure::Anisette(_) => 2,
            SignInFailure::Other(_) => 3,
        }
    }

    fn message(self) -> String {
        match self {
            SignInFailure::Cancelled => "cancelled".to_string(),
            SignInFailure::Anisette(m) | SignInFailure::Other(m) => m,
        }
    }
}

/// A report in one line: what Apple said when it said something, else each step
/// that failed, outermost first, then why the request behind it never got out.
fn describe(report: &Report) -> String {
    for node in report.iter_reports() {
        if let Some(SideloadError::AuthWithMessage(code, message)) = node.downcast_current_context::<SideloadError>() {
            return format!("Apple said: {message} (error {code})");
        }
    }
    let mut parts: Vec<String> = Vec::new();
    let mut add = |text: String| {
        let text = text.trim().to_string();
        if !text.is_empty() && !parts.iter().any(|part| part.contains(&text)) {
            parts.push(text);
        }
    };
    for node in report.iter_reports() {
        add(node.format_current_context().to_string());
        let mut source = node.current_context_error_source();
        while let Some(error) = source {
            add(error.to_string());
            source = error.source();
        }
    }
    parts.join(": ")
}

/// A token's `expiry` as Unix seconds, or None when Apple sent none. Apple does not
/// document the unit, so both milliseconds and seconds are read.
fn stated_expiry(expiry: u64) -> Option<u64> {
    match expiry {
        e if e >= 100_000_000_000 => Some(e / 1000),
        e if e >= 1_000_000_000 => Some(e),
        _ => None,
    }
}

/// When the token runs out, in Unix seconds: Apple's stated expiry, else its
/// duration from `now`. None when Apple gave neither.
fn token_expires(token: &AppToken, now: u64) -> Option<u64> {
    stated_expiry(token.expiry).or_else(|| (token.duration > 0).then(|| now.saturating_add(token.duration)))
}

/// What Swift gets back: the makings of a `SigningAccount`, and the teams to pick
/// its team from.
fn result_json(
    adsid: &str,
    token: &AppToken,
    now: u64,
    identifier: &[u8],
    provisioning: &[u8],
    teams: &[DeveloperTeam],
) -> String {
    json!({
        "adsID": adsid,
        "token": token.token,
        "tokenExpires": token_expires(token, now),
        "anisetteIdentifier": BASE64_STANDARD.encode(identifier),
        "anisetteProvisioning": BASE64_STANDARD.encode(provisioning),
        "teams": teams.iter().map(|team| json!({
            "id": team.team_id,
            "name": team.name,
            "type": team.r#type,
        })).collect::<Vec<_>>(),
    })
    .to_string()
}

/// The anisette provider for `server`, holding `identity` (16 bytes and Apple's
/// provisioning for them) when there is one to sign in as again, so that Apple
/// sees the machine it already trusts. Without one, the first use provisions a
/// new identity.
fn provider(server: &str, identity: Option<(&[u8], &[u8])>) -> Result<RemoteV3AnisetteProvider, SignInFailure> {
    // isideload's HTTPS clients take the process's crypto provider and panic
    // without one. Setting it twice is refused, which is fine.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let mut provider = RemoteV3AnisetteProvider::new(server, Box::new(InMemoryStorage::new()), "0".to_string())
        .map_err(|e| SignInFailure::Anisette(describe(&e)))?;
    if let Some((identifier, provisioning)) = identity
        && let Ok(identifier) = <[u8; 16]>::try_from(identifier)
        && !provisioning.is_empty()
    {
        provider.state = Some(Default::default());
        if let Some(state) = provider.state.as_mut() {
            state.keychain_identifier = identifier;
            state.adi_pb = Some(provisioning.to_vec());
        }
    }
    Ok(provider)
}

async fn sign_in(
    apple_id: &str,
    password: &str,
    server: &str,
    identity: Option<(&[u8], &[u8])>,
    two_factor: TwoFactor,
) -> Result<String, SignInFailure> {
    let cancelled = two_factor.cancelled.clone();
    let provider = Arc::new(RwLock::new(provider(server, identity)?));

    // Apple's address book (no sign-in yet), then the identity's first headers,
    // which is where a server that is down or an identity Apple does not take shows.
    let account = AppleAccount::new(apple_id, AnisetteDataGenerator::new(provider.clone()), false, None, Some(3));
    let mut account = match tokio::time::timeout(SETUP_TIMEOUT, account).await {
        Ok(Ok(account)) => account,
        Ok(Err(e)) => return Err(SignInFailure::Other(format!("Apple could not be reached ({})", describe(&e)))),
        Err(_) => return Err(SignInFailure::Other("Apple did not answer in time".to_string())),
    };
    let headers = account.anisette_generator.get_anisette_data(account.grandslam_client.clone());
    match tokio::time::timeout(SETUP_TIMEOUT, headers).await {
        Ok(Ok(_)) => {}
        Ok(Err(e)) => return Err(SignInFailure::Anisette(describe(&e))),
        Err(_) => return Err(SignInFailure::Anisette("it did not answer in time".to_string())),
    }

    let asked = account.login(password, move |params| std::future::ready(Ok::<_, Report>(two_factor.ask(&params)))).await;
    if let Err(e) = asked {
        return Err(if cancelled.load(Ordering::SeqCst) {
            SignInFailure::Cancelled
        } else {
            SignInFailure::Other(describe(&e))
        });
    }

    let token = account.get_app_token("xcode.auth").await.map_err(|e| SignInFailure::Other(describe(&e)))?;
    let adsid = account
        .spd
        .as_ref()
        .and_then(|spd| spd.get("adsid"))
        .and_then(|value| value.as_string())
        .ok_or_else(|| SignInFailure::Other("Apple's answer named no account".to_string()))?
        .to_string();
    let teams = DeveloperSession::new(
        token.clone(),
        adsid.clone(),
        account.grandslam_client.clone(),
        account.anisette_generator.clone(),
    )
    .list_teams()
    .await
    .map_err(|e| SignInFailure::Other(describe(&e)))?;

    let provider = provider.read().await;
    let (identifier, provisioning) = provider
        .state
        .as_ref()
        .and_then(|state| state.adi_pb.as_ref().map(|adi_pb| (state.keychain_identifier, adi_pb.clone())))
        .ok_or_else(|| SignInFailure::Anisette("the sign-in left no anisette identity".to_string()))?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    Ok(result_json(&adsid, &token, now, &identifier, &provisioning, &teams))
}

/// Signs in to an Apple ID for the developer portal. Blocks until Apple has
/// answered, which with a second factor is as long as the user takes.
///
/// `identity`/`provisioning` are the anisette identity of an earlier sign-in to
/// sign in as again, or NULL for a new one. On success returns 0 and `*result`
/// holds JSON: `adsID`, `token`, `tokenExpires` (Unix seconds, or null),
/// `anisetteIdentifier` and `anisetteProvisioning` (base64) and `teams`
/// (`id`, `name`, `type`). Otherwise `*error` is set and the result is 1 when
/// the user gave up at the second factor, 2 when the anisette server gave
/// nothing Apple takes (another may), 3 for anything else, Apple's refusal
/// included. Free both with `madeira_rppairing_string_free`.
///
/// # Safety
/// `apple_id`, `password` and `anisette_server` must be valid NUL-terminated
/// strings; `identity`/`identity_len` and `provisioning`/`provisioning_len`
/// readable or NULL; `result` and `error` NULL or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn madeira_apple_sign_in(
    apple_id: *const c_char,
    password: *const c_char,
    anisette_server: *const c_char,
    identity: *const u8,
    identity_len: usize,
    provisioning: *const u8,
    provisioning_len: usize,
    two_factor: MadeiraAppleTwoFactorCallback,
    context: *mut c_void,
    result: *mut *mut c_char,
    error: *mut *mut c_char,
) -> i32 {
    let text = |pointer: *const c_char| {
        (!pointer.is_null()).then(|| unsafe { CStr::from_ptr(pointer) }.to_str().ok()).flatten().filter(|text| !text.is_empty())
    };
    let (Some(apple_id), Some(password), Some(server)) = (text(apple_id), text(password), text(anisette_server)) else {
        set_error(error, "missing Apple ID, password or anisette server");
        return 3;
    };
    let identity = (!identity.is_null() && !provisioning.is_null()).then(|| unsafe {
        (std::slice::from_raw_parts(identity, identity_len), std::slice::from_raw_parts(provisioning, provisioning_len))
    });
    let two_factor = TwoFactor { callback: two_factor, context, cancelled: Arc::new(AtomicBool::new(false)) };

    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(e) => {
            set_error(error, format!("could not start the runtime: {e}"));
            return 3;
        }
    };
    // A panic must not unwind into Swift.
    let signed_in = catch_unwind(AssertUnwindSafe(|| runtime.block_on(sign_in(apple_id, password, server, identity, two_factor))));
    match signed_in {
        Ok(Ok(json)) => {
            if !result.is_null() {
                unsafe { *result = CString::new(json).unwrap_or_default().into_raw() };
            }
            0
        }
        Ok(Err(failure)) => {
            let code = failure.code();
            set_error(error, failure.message());
            code
        }
        Err(_) => {
            set_error(error, "the sign-in stopped unexpectedly");
            3
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use isideload::anisette::AnisetteProvider;
    use isideload::auth::apple_account::TrustedNumber;
    use rootcause::prelude::*;
    use std::ptr;

    fn params(unknown: bool, sms: bool, selected: Option<u32>, last_error: Option<&str>) -> TwoFactorCallbackParams {
        TwoFactorCallbackParams {
            last_error: last_error.map(str::to_string),
            unknown,
            sms,
            numbers: vec![TrustedNumber {
                number_with_dial_code: "+39 ••• ••• ••89".to_string(),
                last_two_digits: "89".to_string(),
                push_mode: "sms".to_string(),
                id: 1,
            }],
            selected_number_id: selected,
        }
    }

    #[test]
    fn the_request_says_how_the_code_travels() {
        let device: Value = serde_json::from_str(&request_json(&params(false, false, None, None))).unwrap();
        assert_eq!(device["method"], "device");
        assert_eq!(device["selectedNumberId"], Value::Null);
        assert_eq!(device["lastError"], Value::Null);
        assert_eq!(device["numbers"], json!([{"id": 1, "number": "+39 ••• ••• ••89", "pushMode": "sms"}]));

        let texted: Value = serde_json::from_str(&request_json(&params(false, true, Some(1), Some("Incorrect verification code")))).unwrap();
        assert_eq!(texted["method"], "sms");
        assert_eq!(texted["selectedNumberId"], 1);
        assert_eq!(texted["lastError"], "Incorrect verification code");

        let choose: Value = serde_json::from_str(&request_json(&params(true, true, None, None))).unwrap();
        assert_eq!(choose["method"], "choose");
    }

    #[test]
    fn answers_become_what_the_sign_in_does_next() {
        assert!(matches!(answer(br#"{"action":"code","code":" 123456 "}"#), TwoFactorCallbackResponse::SubmitCode(code) if code == "123456"));
        assert!(matches!(answer(br#"{"action":"sms","id":2}"#), TwoFactorCallbackResponse::SendSms(2)));
        assert!(matches!(answer(br#"{"action":"devices"}"#), TwoFactorCallbackResponse::SendToDevices));
        assert!(matches!(answer(br#"{"action":"resend"}"#), TwoFactorCallbackResponse::ResendCode));
        for unreadable in [&b""[..], b"{", br#"{"action":"code"}"#, br#"{"action":"code","code":""}"#, br#"{"action":"sms"}"#, br#"{"action":"call","id":1}"#] {
            assert!(matches!(answer(unreadable), TwoFactorCallbackResponse::Abort), "{}", String::from_utf8_lossy(unreadable));
        }
    }

    extern "C" fn typed_code(context: *mut c_void, request: *const c_char, reply: *mut c_char, capacity: usize) -> i32 {
        let request: Value = serde_json::from_str(unsafe { CStr::from_ptr(request) }.to_str().unwrap()).unwrap();
        unsafe { *(context as *mut String) = request["method"].as_str().unwrap().to_string() };
        let answer = br#"{"action":"code","code":"654321"}"#;
        assert!(answer.len() < capacity);
        unsafe { ptr::copy_nonoverlapping(answer.as_ptr(), reply.cast::<u8>(), answer.len()) };
        1
    }

    extern "C" fn closed(_: *mut c_void, _: *const c_char, _: *mut c_char, _: usize) -> i32 {
        0
    }

    #[test]
    fn the_callback_is_asked_and_giving_up_is_remembered() {
        let mut seen = String::new();
        let asking = TwoFactor { callback: Some(typed_code), context: (&raw mut seen).cast(), cancelled: Arc::new(AtomicBool::new(false)) };
        assert!(matches!(asking.ask(&params(false, false, None, None)), TwoFactorCallbackResponse::SubmitCode(code) if code == "654321"));
        assert_eq!(seen, "device");
        assert!(!asking.cancelled.load(Ordering::SeqCst));

        for callback in [Some(closed as extern "C" fn(*mut c_void, *const c_char, *mut c_char, usize) -> i32), None] {
            let giving_up = TwoFactor { callback, context: ptr::null_mut(), cancelled: Arc::new(AtomicBool::new(false)) };
            assert!(matches!(giving_up.ask(&params(false, false, None, None)), TwoFactorCallbackResponse::Abort));
            assert!(giving_up.cancelled.load(Ordering::SeqCst));
        }
    }

    #[test]
    fn a_token_runs_out_when_apple_says_or_after_its_duration() {
        let token = |duration, expiry| AppToken { token: "t".to_string(), duration, expiry };
        assert_eq!(token_expires(&token(0, 1_790_000_000), 1_760_000_000), Some(1_790_000_000));
        assert_eq!(token_expires(&token(0, 1_790_000_000_000), 1_760_000_000), Some(1_790_000_000));
        assert_eq!(token_expires(&token(3600, 0), 1_760_000_000), Some(1_760_003_600));
        assert_eq!(token_expires(&token(0, 0), 1_760_000_000), None);
    }

    #[test]
    fn the_result_carries_the_account_the_identity_and_the_teams() {
        let teams = vec![DeveloperTeam {
            name: Some("Ada Lovelace (Personal Team)".to_string()),
            team_id: "ABCDE12345".to_string(),
            r#type: Some("Individual".to_string()),
            status: None,
        }];
        let token = AppToken { token: "portal-token".to_string(), duration: 0, expiry: 1_790_000_000 };
        let result: Value = serde_json::from_str(&result_json("000123-08-abc", &token, 1_760_000_000, &[7; 16], b"adi", &teams)).unwrap();
        assert_eq!(result["adsID"], "000123-08-abc");
        assert_eq!(result["token"], "portal-token");
        assert_eq!(result["tokenExpires"], 1_790_000_000u64);
        assert_eq!(result["anisetteIdentifier"], BASE64_STANDARD.encode([7u8; 16]));
        assert_eq!(result["anisetteProvisioning"], BASE64_STANDARD.encode(b"adi"));
        assert_eq!(result["teams"], json!([{"id": "ABCDE12345", "name": "Ada Lovelace (Personal Team)", "type": "Individual"}]));
    }

    #[test]
    fn an_earlier_identity_is_signed_in_as_again() {
        let fresh = provider("https://anisette.example", None).unwrap();
        assert!(fresh.state.is_none() && fresh.needs_provisioning().unwrap());

        let kept = provider("https://anisette.example", Some((&[9; 16], b"provisioning"))).unwrap();
        assert!(!kept.needs_provisioning().unwrap());
        let state = kept.state.as_ref().unwrap();
        assert_eq!(state.keychain_identifier, [9; 16]);
        assert_eq!(state.adi_pb.as_deref(), Some(&b"provisioning"[..]));

        // One that is not an identity is left out, and a new one is provisioned.
        for (identifier, provisioning) in [(&[9u8; 15][..], &b"provisioning"[..]), (&[9u8; 16][..], &b""[..])] {
            assert!(provider("https://anisette.example", Some((identifier, provisioning))).unwrap().state.is_none());
        }
    }

    #[test]
    fn a_failure_says_what_apple_said() {
        let refused = || -> Result<(), Report> {
            Err(report!(SideloadError::AuthWithMessage(-22406, "Enter the correct password for this Apple Account.".to_string())))
                .context("Failed to log in to Apple ID")?;
            Ok(())
        };
        assert_eq!(describe(&refused().unwrap_err()), "Apple said: Enter the correct password for this Apple Account. (error -22406)");

        let unreachable = || -> Result<(), Report> {
            let sent: Result<(), std::io::Error> = Err(std::io::Error::other("nodename nor servname provided"));
            sent.context("Failed to fetch URL Bag")?;
            Ok(())
        };
        assert_eq!(describe(&unreachable().unwrap_err()), "Failed to fetch URL Bag: nodename nor servname provided");
    }

    #[test]
    fn a_sign_in_needs_its_arguments() {
        let mut error: *mut c_char = ptr::null_mut();
        let code = unsafe {
            madeira_apple_sign_in(c"".as_ptr(), c"password".as_ptr(), c"https://anisette.example".as_ptr(), ptr::null(), 0, ptr::null(), 0, None, ptr::null_mut(), ptr::null_mut(), &mut error)
        };
        assert_eq!(code, 3);
        assert!(!error.is_null());
        unsafe { crate::madeira_rppairing_string_free(error) };
    }
}
