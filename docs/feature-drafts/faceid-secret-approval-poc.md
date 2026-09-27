# Face ID secret approval proof of concept

Implemented on `poc/faceid-secret-approval`, Debug builds only. The first experiment uses a random
disposable credential. The second permits one authenticated GitHub profile request per approval,
using a dedicated token entered locally on the Mac. Neither mode unlocks arbitrary Keychain items.

## GitHub profile trial

1. Launch the provisioned **Threading FaceID** Mac variant, then open **Settings → Remote Access
   → Developer**. The GitHub controls stay disabled unless protected Keychain storage and hardened
   signing are available; there is no login-Keychain fallback for real tokens.
2. Create a separate [fine-grained GitHub token](https://github.com/settings/personal-access-tokens/new)
   for your own account, with a short expiry, public repositories only and no added permissions.
   [GET /user requires no additional fine-grained permissions](https://docs.github.com/en/rest/users/users#get-the-authenticated-user).
   Never paste the token into a chat, shell argument, environment variable or configuration file.
3. Stop any existing experiment. Enter the token in the Mac's masked **GitHub trial token** field
   and click **Start GitHub trial**. This stores only that item in the protected, nonsynchronizing,
   `WhenUnlockedThisDeviceOnly` Keychain. The field clears immediately; the app does not contact
   GitHub or read the stored token during enrollment.
4. On the paired iPhone, open **Settings → Developer → Face ID approval**, enter the new enrollment
   code, enroll, and choose **Request operation**. Review `GET https://api.github.com/user`, then
   **Approve with Face ID**. Success reads **GitHub verified: <username>**.
5. **Stop experiment** removes the local trial token and approval authority. Revoke the token
   on GitHub when finished. Stopping cannot recall an HTTPS request already sent, but suppresses
   its result. A crash drops authority; Start or Stop removes an orphaned stored trial token.

The method, destination, credential label and operation are signed with the existing one-use
challenge. The phone validates that exact supported tuple before Face ID. A disposable-credential
approval cannot authorize GitHub. The Mac uses an ephemeral HTTPS session with normal certificate
validation, no cookies, cache, credential store, redirects or application retries, a seven-second
resource timeout and a 32-KiB streamed response cap. Only the validated username (at most 39 ASCII
bytes) and matching receipt reach the phone; profile email, biography and other fields are dropped.
The token necessarily reaches GitHub in the Authorization header, never the phone or chat.

The Mac checks a team-backed hardened signature, denies debugger/foreign-library/DYLD-injection
entitlements, and probes protected Keychain availability before enabling token entry or storage.
This is still an experiment trusting the installed apps and local enrollment, not protection from
a compromised Mac, malicious code signed by the same trusted developer, or remote hardware
attestation. No existing GitHub credentials are discovered or reused automatically.

## Disposable-credential trial

For the local side-by-side device trial, the generated iPhone variant is named **Threading
FaceID** (`codes.threading.mobile.faceid`). Launch its matching Mac copy using
`.build/faceid-variant/Launch Threading FaceID.command` in this worktree. That launcher gives
the Mac a separate state directory at `.build/faceid-variant/mac-state`; pair the phone with
this instance's QR code. The provisioned GitHub Mac build uses the registered `codes.threading`
bundle ID, an explicit `codes.threading.faceid` remote-service namespace, and the dedicated
`SMQ3E8Y57T.codes.threading.faceid` Keychain access group. Always use this launcher to preserve
state isolation from the regular app; do not open the GitHub app bundle directly. The generated variant omits push, universal-link and shared widget
entitlements so it can use the installed development profile without sharing those features
with the regular app. Use the in-app pairing scanner and direct pinned HTTPS for this trial.
These generated artifacts are local build output, not a shipping configuration.
The device variant was development-signed, installed and successfully launched on David's
iPhone 16 Pro on 2026-09-19. This verifies installation and startup, not biometric approval.
After adding separate remote Keychain service names for alternate Debug bundle IDs, all
19 focused Mac credential-store and approval tests passed before refreshing the Mac variant.

1. Build and run the **Threading** Debug scheme on your Mac and the **ThreadingMobile** Debug
   scheme on a physical Face ID iPhone. The Simulator intentionally cannot sign approvals.
2. Pair your iPhone normally. Use the Mac's pinned HTTPS LAN or Tailscale address; this first
   experiment refuses unpinned and Hosted Direct loopback routes.
3. On the Mac, open **Settings → Remote Access → Developer → Start experiment**.
4. On iPhone, open **Settings → Developer → Face ID approval**. Enter the Mac's eight-digit code
   within five minutes and select **Enroll with Face ID protection**.
   Registration dismisses the keyboard and shows its result directly below that button. Creating
   the protected key need not show a Face ID prompt; the biometric prompt belongs to approval in
   the next step. If registration is refused, stop/start the Mac experiment and enter the new
   code. Connection, pairing, preview and code-validation failures have distinct messages.
5. Select **Request operation**, review the request, then **Approve with Face ID**. Success
   means the Mac read only its disposable test item and computed/verified an HMAC internally.
   Only the challenge's receipt ID crosses back to the phone, never the credential or HMAC.
6. Cancel a request or try approving after sixty seconds. Neither should execute the operation.
7. On the Mac, **Stop experiment** deletes the disposable item and drops enrollment and pending
   authority. Closing the phone screen, switching Macs, or backgrounding the app loses its in-memory key wrapper; restart the experiment
   locally before enrolling again. Restarting the Mac app also loses all approval authority.

Ordinary Mac Debug builds are ad-hoc signed. The test item follows `KeychainStoragePolicy`:
protected Keychain when supported, otherwise the login Keychain. The Mac screen explicitly
states the latter is reachable by local processes. This is acceptable only for the random,
non-useful test credential. A crash may leave this one disposable item behind; the next start
of an experiment replaces it, and Stop deletes it. No existing credential is queried or changed.

## Security contract

- Enrollment is enabled on the Mac only, with a five-minute, five-attempt code, one device, and
  one public key. There is no remote enable, key replacement, credential selection or shell API.
- Every request requires a current, device-bound, interactive, all-session owner capability.
  Guests, viewers and legacy unbound owner bearers cannot use the lab. Enrollment is bound to
  the exact owner grant as well as its device ID, so re-pairing cannot reuse enrollment.
- The iPhone requires a direct HTTPS LAN, VPN or Tailscale route with a pin registered for its
  actual hostname in the request session's TLS delegate. Registration and every lab request
  recheck that registry; a QR fragment alone grants nothing. Existing TLS evaluation still
  verifies the server certificate, and Hosted Direct remains unavailable for this experiment.
- The iPhone key is Secure Enclave P-256, with `privateKeyUsage` and `biometryCurrentSet`, and
  `WhenUnlockedThisDeviceOnly` accessibility. No raw private key is exported. Each approval uses
  a fresh `LAContext`, biometric-only policy and no reuse interval or passcode fallback.
  Re-enrolling Face ID invalidates use of the enrolled key; no software-key fallback exists.
- Signed, domain-separated canonical bytes include experiment ID, unpredictable challenge UUID,
  device ID, deadline, fixed credential label and fixed operation. The host verifies the bytes
  it issued, rather than trusting request-supplied descriptions.
- There is one pending operation, expiring after sixty seconds. Repeated challenge requests do
  not extend it. Approval consumes it before Keychain access, even when that access fails.
  Cancellation removes it; a new operation gets a new challenge. Turning Remote Access off
  also clears experiment authority and attempts to remove the disposable item.
- Approval routes bypass the general REST replay cache and the client never retries them
  automatically. A lost response is ambiguous; it must not silently repeat the operation.
- The broker rechecks current remote authority immediately before consuming approval. Work
  already authorized and executing cannot be recalled by a later revocation.
- Neither keys, codes, signatures, credentials nor HMACs are written to app logs/transcripts.
  The enrollment code appears only in local settings and the authenticated enrollment request.

A signature proves possession of the enrolled key, **not remote attestation of Face ID or of a
particular app binary**. This PoC trusts the installed iPhone client and the local enrollment
ceremony. Someone with the enrollment code and a valid owner capability could enroll a software
key using a different client. Stronger provisioning/attestation and a threat-model review are
required before offering this for real credentials. A compromised Mac is also outside this
boundary: Threading hosts unrestricted local agent processes, and this lab is not a sandbox.

## Surface and scaling decisions

Both settings surfaces are deliberately host-only diagnostic controls. The host owns enrollment,
key binding, request meaning, credential access, signature validation, expiry and revocation;
there is no public extension component or agent tool. Apple owns the Face ID system prompt.
The existing Remote Access settings destination remains the Mac entry point.

Expected and stress retained state are both one experiment, one device, one public key and one
challenge. Requests are at most 2 KiB, responses at most 4 KiB on the phone; the existing remote
server bounds connections. All expensive Keychain and crypto calls run on actors off the main
actor. No polling, directory scans, transcript reads, or externally sized view stacks are added.

## Verification and remaining work

`SecretApprovalLabTests` covers successful use, replay, changed signed bytes, wrong key/device/
grant, expiration, cancellation, disabled state, enrollment expiry/attempt limits and a credential
failure consuming the approval. The remote server integration test exercises actual HTTP auth,
owner binding and replay-cache bypass. These use test keys and an injected credential operation,
so they never touch a developer's Keychain and do not prove physical Face ID behavior.

The iPhone tests also check missing enrollment, request/device validation, the built Face ID
usage description, and refusal of Simulator enrollment.
On 2026-09-20 the registration-feedback update passed nine focused simulator tests, including
rejection of missing pairing, previews and unpinned/Hosted Direct connections before key creation,
pasted-code validation, and safe registration-refusal copy. The updated variant was installed and
launched on the physical iPhone. The reported attempt's journal confirms successful LAN pairing.
The visible refusal then identified a preflight bug: the lab required a fingerprint fragment in
the active URL, but pairing replaces that URL while retaining the full certificate fingerprint
in the paired-host record and TLS delegate. The lab now consults that delegate, just like its
HTTPS requests. The regression follows pairing, host merge, pin registration and live-route
selection with a fragment-free URL. Negative cases cover unrelated host pins, a revoked pin
despite an old QR fragment, HTTP and non-direct routes. No re-pairing is needed for an already
pinned LAN connection; no pin or TLS check is bypassed.
The correction passed 38 focused simulator tests (11 lab, 22 certificate trust and five live-route
tests). The device variant was rebuilt, signature-verified, installed and launched on the iPhone
on 2026-09-20. David subsequently confirmed that the physical iPhone displayed the final
"Approved once" success message. That message requires the Mac's matching receipt after
signature verification and successful use of the disposable credential. This records a
user-confirmed hardware success path, not an independently captured screen or approval log;
the diagnostic journals confirm LAN connectivity but do not record the lab's approval result.
The UI evidence workflow captured a real registration-button tap after opening the code keyboard;
the inspected result shows the refusal beside the button with the keyboard dismissed. Updated
light, dark, system and pending-approval captures are in `.build/faceid-registration-reviewed/`.

Verified on 2026-09-19: both Debug targets build; the focused Mac run passed seven tests
(five broker tests, one real HTTP test, one settings render test), and the iPhone simulator run
passed five tests (four biometric-client contracts and the demo-scene catalogue contract).
Repository build gates and `git diff --check` also passed.

The iOS evidence entry `ios-secret-approval` captures the shipping lab view in three palettes
and the pending-approval state. All four images were inspected in
`.build/faceid-ios-reviewed/report/index.html`. The Mac `remote-credential-storage` render
includes the whole settings shell and asserts the lab's start button is within the capture;
system-light, Cyberpunk and Swiss images were inspected in `.build/faceid-renders/`.
No visual baselines were accepted. Test result bundles are under
`.build/faceid-derived/Logs/Test/` and `.build/faceid-mobile-derived/Logs/Test/`.

The starting branch also needed two compilation repairs: misplaced existing project-visibility
declarations in `SessionDashboard.swift` and a test protocol method placed on the wrong fake in
`RemoteServerIntegrationTests.swift`. These move the existing code to its intended scope.

Physical iPhone cancellation, biometric lockout, Face ID re-enrollment and lock/lifecycle races
still need hardware trials. The successful user trial does not verify those refusal paths.
Do not describe simulator screenshots or software-key tests as proof of biometric enforcement.

Before broader use: review enrollment/provisioning and same-developer-code trust, test phone/Mac
lock and lifecycle races on hardware, and define recovery without silent credential export.
Existing Mac Keychain items requiring local authentication cannot be unlocked by this protocol.

The GitHub iteration passed 32 focused Mac tests and 13 focused iPhone tests and six inspected screen captures (including
the exact GitHub approval and username result) in `.build/faceid-github-ios-reviewed/`. Mac tests
exercise the real HTTP approval route with an injected GitHub operation, the bounded URLSession
path against fixture responses, all redirect refusals, protected-store failures without fallback,
signature purpose binding, one-use failure semantics, and stop during an in-flight request.
No account token is used by these tests. A separately signed check compiled from the actual store
code and scoped to a unique disposable item verified protected Keychain create/read/delete with
the trial profile and hardened entitlements; its report is
`/tmp/threading-faceid-protected-storage-result.json`. The hardened Mac bundle passed deep, strict signature verification and launched through the
isolated-state launcher; its diagnostic journal confirmed LAN listener binding and discovery.
The updated iPhone variant was installed and launched on 2026-09-20. A live GitHub success still
requires local token entry and the user's Face ID interaction.

Apple references: [Secure Enclave](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave),
[biometryCurrentSet](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/biometrycurrentset),
[biometric-only authentication](https://developer.apple.com/documentation/localauthentication/logging-a-user-into-your-app-with-face-id-or-touch-id).
