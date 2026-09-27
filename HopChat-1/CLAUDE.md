# hoppin — Project Context for Claude Code

## What this is

hoppin is an iOS (18+) SwiftUI messenger. Messages are **end-to-end encrypted**,
delivered **directly over the local network** when both devices are on it, and
otherwise through a **relay server that stores only sealed envelopes it cannot
read**. Identity is a phone number **verified once by SMS**; the server then
issues a signed identity certificate binding that number to the device's keys.

This replaced a v1 design that was serverless-by-DHT and insecure (unverified
phone numbers, keys accepted from any inbound message, plaintext fallback,
open phone→IP lookup). None of the v1 protocol survives.

**`docs/DESIGN_CONTRACT.md` at the repo root is the binding spec** for the wire
format, canonical signing encoding, certificates, envelope sealing, server
policy and the Swift API surface. Read it before changing anything that crosses
the Swift ⇄ Python boundary; the two sides are verified against shared fixtures
in `docs/fixtures/crypto_vectors.json`.

---

## Layout

| Path | Role |
|------|------|
| `App/HopChat_1App.swift`, `App/AppDelegate.swift` | Entry point, notification delegate, scene lifecycle |
| `App/AppConfig.swift` | Server host/ports, pinned server key + TLS SPKI pins, URLs, limits |
| `App/Log.swift` | `Log.net/crypto/store/ui/app` — os.Logger; phones/IPs/content are `.private` |
| `Identity/Canonical.swift` | Length-prefixed field encoding used for every signature and AEAD header |
| `Identity/PhoneNumber.swift` | E.164 normalization (249-entry calling-code table), masking |
| `Identity/IdentityCertificate.swift` | Server-signed `phone → signingKey + agreementKey`, 30-day validity |
| `Identity/KeychainStore.swift` | `KeyValueSecureStore` protocol, Keychain + in-memory implementations |
| `Identity/CryptoManager.swift` | Identity keys, sealing/opening, weekly agreement-key rotation |
| `Identity/TrustStore.swift` | TOFU pinning, key-change detection, safety numbers, QR verification |
| `Identity/Envelope.swift` | The sealed, signed unit of delivery |
| `Network/WireMessage.swift`, `ChatPayload.swift` | Wire envelope (v2) and the encrypted payload kinds |
| `Network/Transport.swift` | NWConnection framing, timeouts, TLS with SPKI pinning |
| `Network/ServerClient.swift` | Verification, certificates, relay deposit/fetch/ack, report, delete |
| `Network/LANNode.swift`, `BonjourDiscovery.swift`, `KadmeliaNode.swift` | Authenticated LAN peers |
| `Network/Mesh/` | BLE mesh: `MeshPacket`/`CompactEnvelope` (wire), `MeshRouter` (flood, TTL, carry-forward), `BLEFrames` (chunking), `BLETransport` (CoreBluetooth), `MeshNode` (wiring, `MeshDelivering`) |
| `Network/HoppinService.swift` | `KademliaService` — the only network API the views use |
| `Storage/` | File-backed store (`ConversationStore`), serial `StoreWriter`, media, legacy migration |
| `Services/` | Notifications, APNs token registration, app lock (Face ID), background relay fetch |
| `Views/` | SwiftUI; `Shared/` holds `AvatarView`, `PresenceDot`, `KeyChangeBanner` |
| `../bootstrap.py`, `../server/` | Relay + verification server, its tests, TLS script, deploy notes |

---

## How a message moves

**Send** — `sendText(_:to:)` stores `.pending` → ensure a valid pinned certificate
for each recipient (refuse if a key change is pending) → `CryptoManager.seal`
(per-message ephemeral X25519 + static-static ECDH → HKDF → AES-GCM, header as
AEAD data, Ed25519 signature) → authenticated LAN peer if there is one, else
`relayDeposit` → `.sent` → delivery receipt `.delivered` → read receipt `.read`.
Failures stay `.pending`, retry with backoff, and become `.failed` after 7 days.
Each stored message records its `route` (`.direct` / `.relay`); the UI shows a
"sent directly" mark for `.direct`.

**LAN** — Bonjour `_hoppin._tcp` + a signed hello; listener, browser, published
service and outbound connections all allow peer-to-peer Wi-Fi (AWDL), so two
iPhones can connect even on client-isolated networks (eduroam, hotels). Link-local
IPv6 peer addresses keep their `%interface` scope end to end. Peers count as online
for 5 min after last contact; a keep-alive pings recent peers every 60 s. A peer
that proved its certificate in the LAN exchange is sent to without a server
certificate lookup, so Wi-Fi with no internet doesn't stall on timeouts.

**Direct across networks** — with no LAN peer and no path the relay can carry,
a contact that published a global IPv6 address (inside a sealed `addressHint`)
is dialled directly before the relay is tried. Contract §10.

**Mesh** — with no network path at all (and `hoppin.mesh.enabled` on), a text,
receipt, profile or delete hops over Bluetooth: the same sealed envelope inside
an anonymous outer layer, forwarded by phones that cannot read it. Tried after
LAN and before the relay; the radio only runs while the phone is offline.
Messages record `route == .mesh` and are re-sent through the relay when
internet returns (the recipient de-duplicates by envelope id). Photos and
typing never go on the mesh. Contract §9.

**Receive** — long-poll `relayFetch` while active, `BGAppRefreshTask`
(`com.hoppin.relay-fetch`) in the background. Validation order is fixed and
must not be reordered: certificate valid + bound to the claimed phone → agreement
key current or recently pinned → envelope signature → addressed to us, within 7
days, not already seen → trust evaluation → block list → decrypt. Then persist,
`flush()`, and only then ack.

**`IngestOutcome` matters.** `.accepted`/`.rejected` are acked; `.retryLater`
(locked Keychain, pending key change, disk failure) is deliberately **not**
acked and not recorded as seen, so the relay redelivers. Acking a transient drop
deletes the user's mail permanently — that was a real bug; keep the distinction.

---

## Rules worth keeping

- **Never trust anything self-reported on the wire**: not `senderPhone`, not a
  node id, not `senderIP`. A peer's address is the TCP source; a peer's identity
  is its certificate.
- **No plaintext fallback, ever.** If the recipient's keys aren't available the
  message stays queued; it is never sent in the clear.
- **Never regenerate identity keys on a Keychain error** — only when the item is
  genuinely absent. v1 wiped identities whenever the device was locked.
- **Never auto-replace a pinned signing key.** A change raises a warning, blocks
  sending, and defers incoming mail until the user verifies or accepts.
- The server learns phone numbers, IPs and timing. It cannot read content. Don't
  add anything that weakens that, and don't describe the app as serverless.
- Secrets live in the Keychain (`AfterFirstUnlockThisDeviceOnly`), conversations
  in protected files excluded from backup. UserDefaults holds only preferences
  (the exact key list is §6 of the contract).

---

## Running and testing

```bash
# Server (dev): fixed code, plaintext, ephemeral state
HOPPIN_ENV=dev HOPPIN_ALLOW_PLAINTEXT=1 HOPPIN_DEV_FIXED_CODE=123456 ./venv/bin/python bootstrap.py

./venv/bin/python -m unittest discover -s server     # server suite
./scripts/run_tests.sh                               # server + app tests end to end
```

Xcode's command-line tools are not selected on this machine — prefix builds with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The project uses
file-system synchronized groups, so new files under `HopChat-1/` are compiled
automatically (`CLAUDE.md` is excluded from the bundle).

---

## The relay

Deployed at **`20.199.104.218:4443`** (Azure, France Central, `hoppin-relay`),
running `hoppin-bootstrap.service`. Details, credentials layout and caveats are
in [`docs/DEPLOY.md`](../docs/DEPLOY.md). It runs in `prod` mode with real SMS
through Twilio (sender `hoppin`), and its identity key was generated on the
instance — the Mac-derived key was retired on 25/09/2026.

`AppConfig` now ships the live host, signing key and both TLS SPKI pins, so a
Release build connects without any override. The DEBUG overrides
(`hoppin.dev.serverHost`, `hoppin.dev.serverKey`, `hoppin.dev.serverPins`) are
still there for pointing a development build at a local `bootstrap.py`.

## Open items

- **Push is half wired.** Both ends of the token exist — `PushRegistration`
  (device) and `apns.py` + the `pushToken` op (relay) — but the Xcode project
  has no Push Notifications capability yet, so no token is ever minted and
  notifications are still only local ones fired after a `BGAppRefreshTask`. Once
  the capability and `remote-notification` background mode are added, the banner
  will say "New message" and nothing more: showing the real sender and text
  needs a Notification Service Extension, and that needs the store and Keychain
  to move to an App Group. See `TODO.md` §3.
- Website legal pages contain `[placeholder]` fields (legal name, contact email,
  governing law) that must be filled before submission.
- Export compliance: `ITSAppUsesNonExemptEncryption = false` is correct
  **because** every cipher comes from CryptoKit / Network.framework and no
  third-party crypto is linked. See `docs/EXPORT_COMPLIANCE.md`. Adding a crypto
  package (CryptoSwift, libsodium, OpenSSL, libp2p…) changes that answer.
- App Store text, privacy labels, age rating and review notes live in
  `docs/APP_STORE.md`, with three submission blockers listed at its end.
