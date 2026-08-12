# Physical phone transport probe

This standalone probe keeps WebRTC and test signaling out of the shipping Threading targets. It
can exchange a bounded offer, answer and trickled candidates through its one-use HTTP rendezvous;
the earlier same-LAN gate also supports Bonjour and a probe-only fixed endpoint. A 32 KiB challenge
then travels Mac → iPhone → Mac over the encrypted WebRTC data channel, never the signaling path.

Generate the project and build both targets:

```sh
cd Probes/PeerTransportPhoneProbe
xcodegen generate
xcodebuild -project PeerTransportPhoneProbe.xcodeproj \
  -scheme PeerTransportProbeHost -configuration Debug build
xcodebuild -project PeerTransportPhoneProbe.xcodeproj \
  -scheme PeerTransportProbePhone -configuration Debug \
  -destination 'platform=iOS,id=<device-id>' build
```

Start the Mac host before launching the phone app. Allow incoming connections on macOS and Local
Network access on iOS if prompted. The host prints one `THREADING_PHONE_PROBE PASS` line containing
the selected route and elapsed time.

The probe covers host-only same-network connectivity and STUN-direct cross-network connectivity.
It still does not replace a production authenticated service, TURN fallback, or the wider NAT and
network-change matrix.

## Physical-device result

The 2026-08-11 run between the development Mac and David's iPhone 16 Pro passed on both ends:

- selected ICE pair: host → host over UDP (no relay);
- payload: all 32 KiB verified Mac → iPhone → Mac;
- iPhone negotiation/data time: 103 ms;
- full host-side coordinated round trip: 474 ms.

Bonjour advertised correctly from the Mac but iOS discovery did not deliver a browse result on
this access point. The successful run therefore used the explicit LAN endpoint
`192.168.1.181:51837`. That address is intentionally isolated to this disposable probe and must
never become production discovery or signaling.

The second 2026-08-11 run used a token-protected, memory-bounded rendezvous exposed through a
one-use Cloudflare Quick Tunnel. Only offer, answer and trickled ICE candidates used that HTTP
path. With the Mac on home Wi-Fi and the iPhone on cellular, the 32 KiB encrypted data-channel
challenge passed in both directions. No TURN server was configured, proving the data bytes took a
direct ICE path rather than the Cloudflare signaling tunnel. The host's selected-pair statistic
was sampled during peer teardown and returned `unknown`; the probe now captures both peers' route
statistics before the completion handshake on future runs. The 49.9-second host wall time includes
the manual app-launch interval and is not a connection-time measurement.

Before another hosted run, replace the placeholder rendezvous URL and token in `ProbeWire.swift`
with a newly generated one-use pair. Never reuse a previous tunnel URL or token.
