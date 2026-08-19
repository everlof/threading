# A named Cloudflare Tunnel as the owner's stable address

> Status: **decision record** (2026-08-19). **Reject.** A named Cloudflare Tunnel would give the
> owner's phone a hostname that survives a restart, which is the exact property the Quick Tunnel
> lacks and the property that broke on 2026-08-17. It buys that by permanently installing a third
> party that terminates TLS on the owner's own traffic, and by requiring a Cloudflare account and
> a domain per user. Rejected as a stopgap and rejected as a product. Not implementation work.

Part of the [decisions index](README.md). This is decision 2 of the remote-access transport plan,
written down so the next person does not re-derive it. Read alongside
[`REMOTE_ACCESS.md`](../REMOTE_ACCESS.md), whose transport list and relay bullet are the facts
this rests on.

**The one-sentence version.** The thing a named tunnel fixes is address stability, and a listener
on the Mac's own interface with a sticky port fixes it too, without a third party reading the
traffic and without asking a user to own a domain.

---

## 1. User problem and concrete use cases

1. **The address that changes every launch.** A Quick Tunnel's hostname is
   `https://<random>.trycloudflare.com`, minted per process. A phone paired against one is
   pointing at nothing after the Mac restarts, and the person is told to scan a code again for a
   Mac that never moved. This is the incident of 2026-08-17.
2. **The Mac that is not on this network.** Somebody away from home with a Mac at home, on a
   network they do not control, with no VPN and no tailnet. This is the case a public origin is
   actually for.
3. **A guest link somebody can open.** A shared chat needs a URL that a browser on the open
   internet can reach; that is a public origin by definition, and it is the one place the current
   Quick Tunnel is still the right shape.

Case 1 is what a named tunnel would be reached for. Case 2 is what it would be *justified* by, and
case 3 is the only one it is genuinely the answer to.

---

## 2. Existing Threading behaviour and overlap

- **The relay already exists and is already narrow.** `RemoteTunnel` spawns `cloudflared
  --url http://127.0.0.1:<port>`, scrapes the `trycloudflare.com` hostname out of its output, and
  is started by *creating a guest share* rather than by any setting. It stops when the last share
  is gone. Nothing about it is an owner route any more.
- **The disclosure already exists**, in `docs/REMOTE_ACCESS.md`: "No router port or inbound
  firewall rule is opened for it. Traffic passes through Cloudflare, where TLS is terminated, so
  share only work you are comfortable sending through it." That sentence is the whole argument
  below, already written for the guest case.
- **Address stability is solved elsewhere.** The listener takes a sticky port
  (`RemoteListenerPorts.defaultPort`, walked in a fixed order both ends know), binds the Mac's own
  interfaces, and advertises every address it holds through `/api/me`. A restart changes nothing a
  paired phone has to be told about.
- **Identity is solved elsewhere, and solved in a way a tunnel would undo.** The phone pins one
  self-signed certificate scanned off the Mac's screen. There is no certificate authority in that
  path, which is the property that makes it worth having.
- **Discovery covers the moving-address case** the tunnel was reached for a second time: the LAN
  door announces itself and a paired phone re-resolves after DHCP moves the Mac.

So of the two things a named tunnel would deliver, one is already delivered and the other is case
2, which the plan routes to ICE/TURN rather than to a hostname.

---

## 3. What a named tunnel actually is

A named Cloudflare Tunnel is the same `cloudflared` process with a persistent credential instead of
an anonymous one. The differences that matter:

- **The hostname is yours and it is stable.** `mac.example.com` routes to the tunnel for as long as
  the DNS record and the tunnel credential exist. That is the whole appeal.
- **It requires a Cloudflare account, a zone, and a domain.** The hostname is a DNS record in a
  zone Cloudflare serves. There is no anonymous named tunnel, by construction: the name has to
  belong to somebody.
- **TLS is terminated at Cloudflare, exactly as it is for a Quick Tunnel.** The certificate the
  browser or phone validates is Cloudflare's for that hostname; the leg to the Mac is a separate
  connection `cloudflared` makes to loopback. Cloudflare holds plaintext in the middle. This is
  not a configuration mistake to be fixed with a setting; it is what the product is.
- **It is permanent rather than launch-scoped.** A Quick Tunnel dies with the process, which
  bounds the exposure to the moment a share exists. A named tunnel is credentialed
  infrastructure that comes back on its own.

---

## 4. Why it is rejected

**It inverts the trust story to buy a property already bought.** Everything else in the transport
plan converges on: the Mac presents its own certificate, the phone pins it, nobody in between can
read anything. A named tunnel makes the owner's ordinary daily connection pass through a third
party in plaintext, and it does so to obtain address stability, which a sticky port on a real
interface already provides for free.

**The cost lands on the user, not on us.** "Buy a domain and hold a Cloudflare account" is not a
setup step this product can ask for. Every other way in either works with what the person already
has (the same Wi-Fi, a VPN they already run) or is one install they were going to do anyway
(Tailscale).

**A permanent public origin is exposure nobody asked for.** The current design is deliberate that
the relay runs *only while a guest link exists*. A named tunnel that is up because it is
configured is a public front door to the Mac's remote surface, held open by a credential on disk,
whether or not anybody is using it.

**As a stopgap it is worse than as a product.** Shipping it "temporarily" means shipping the
disclosure, the setup flow, the credential storage and the support surface, all of which have to
be maintained until ICE/TURN lands, and then removed. The interim value over what already ships is
case 2 only, which is precisely the case ICE/TURN is being designed for.

---

## 5. Security and privacy analysis

- **Confidentiality.** Plaintext at Cloudflare for every owner request: terminal bytes, prompts,
  conversation content, file diffs, attachment payloads. The bearer token travels through it too.
- **Identity.** The phone would have to accept a publicly issued certificate for the tunnel
  hostname rather than the Mac's pinned one, so the one guarantee this plan is built on stops
  applying to the owner's usual route. That is the same exception Tailscale Serve holds today, and
  it is held there for a *browser* convenience, not for the app's main path.
- **Durability of exposure.** A credential on disk that an agent's own shell can read, backing a
  hostname that resolves whether or not Threading is running.
- **Naming.** A stable hostname in public DNS is itself a disclosure: `mac.example.com` ties a
  machine to a person's domain, and certificate transparency logs carry the name. The plan already
  refuses this for Tailscale Serve unless it is explicitly asked for.

---

## 6. Recommendation

**Reject.** Keep the Quick Tunnel exactly where it is: guest shares only, started by creating one,
stopped when the last one is gone, with the TLS-termination sentence beside it. Owner routes stay
on the Mac's own interfaces with a pinned certificate, and reaching a Mac from outside the network
is ICE/TURN's problem, where the encryption is end to end and the third party carries bytes it
cannot read.

---

## 7. What should reopen this

**A decision to operate per-user infrastructure.** That is the specific trigger. If Threading ever
runs its own hostnames on behalf of users, so that the account and the domain are ours rather than
theirs, the setup objection disappears and only the TLS objection remains. Reopen it *then*, and
answer the remaining question directly: whether the terminating party is us or Cloudflare, and
whether the connection can be end to end through it anyway. Threading Direct's rendezvous is the
shape of that answer, and it is why the hosted service is designed to introduce two devices rather
than to carry their traffic.

Two things that are **not** reasons to reopen it:

- **A user who owns a domain already.** A way in that only works for people with a zone in
  Cloudflare is not a way in this product offers; it is a support burden with a small audience.
- **ICE/TURN being delayed.** The stopgap argument is the one §4 answers. If reaching a Mac from
  outside is urgent before ICE/TURN lands, the honest interim answers are Tailscale and a VPN,
  both of which are already on the page and neither of which reads the traffic.
