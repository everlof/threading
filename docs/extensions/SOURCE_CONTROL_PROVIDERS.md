# Source-control provider extensions

`source-control.read` lets a safe WebAssembly extension teach Threading how to read a hosted Git
service without teaching the extension how to acquire credentials, inspect checkouts, or draw app
UI. The provider returns one provider-neutral change-request summary. Git Review and native
workspace navigators consume that same host-owned value.

The boundary is deliberately read-only. Creating a pull or merge request, pushing a ref, changing
review state, and merging remain built-in host operations until each has its own typed authority
and confirmation contract.

## Ownership and flow

1. Threading reads the checkout's remote, branch, and HEAD away from the main actor.
2. An exact lowercase remote host selects at most one user-approved provider connection. GitHub
   and GitLab.com remain reserved for their built-in providers.
3. Threading sends the provider repository coordinates, never the checkout path or complete remote
   URL.
4. The extension asks `ExtensionHostClient.sourceControlFetch` for `GET` or `HEAD` paths below its
   declared API prefix.
5. Threading constructs the exact HTTPS origin and authentication header from host-owned connection
   state. The credential never enters the process wire response.
6. The extension decodes provider JSON and returns a bounded `ExtensionSourceControlResponse`.
7. Threading validates repository state and web origin, maps the response to its shared
   `ChangeRequestSummary`, and publishes only the provider-neutral native-plugin payload.

Connection metadata is recoverably stored in app preferences. Tokens are stored separately in the
Keychain under a host namespace. A connection can be added or removed in **Settings → Extensions**;
removal deletes the Keychain credential. Redirects stay on the same scheme, host, port, method, and
declared API prefix. Response bodies, headers, query items, strings, counts, and concurrent reads
are bounded.

## Manifest and registration

Declare the capability and one or more definitions in `threading-extension.json`:

```json
{
  "capabilities": ["source-control.read"],
  "sourceControlProviders": [
    {
      "id": "forgejo",
      "displayName": "Forgejo",
      "changeRequestName": "pull request",
      "changeRequestPluralName": "pull requests",
      "apiPathPrefix": "/api/v1",
      "authenticationKinds": ["authorization-token", "none"],
      "reportsChecks": true,
      "reportsApprovals": true,
      "reportsChangesRequested": true
    }
  ]
}
```

Repeat the exact definitions in `ExtensionRegistration.sourceControlProviders`. A mismatch rejects
the process generation. Do not also declare `network.brokered` or an origin grant for these calls:
the user's connection supplies the origin at runtime, while the definition supplies the only path
prefix the provider can address.

Authentication is a closed vocabulary:

- `none` attaches no credential;
- `bearer-token` constructs `Authorization: Bearer <token>`;
- `authorization-token` constructs `Authorization: token <token>`;
- `basic-username-token` constructs Basic authentication from the stored username and token.

The extension may add ordinary safe request headers, but cannot set authorization, cookies, host,
proxy, forwarding, or other denied authority headers.

## Process protocol

Threading sends correlated `ExtensionSourceControlRequest` values for:

- `probe`, to verify that a configured service answers;
- `discover`, to find the request for an exact branch and HEAD;
- `lifecycle`, to re-check one known request number.

The extension sends a response with the same request ID. A summary carries the request number,
bounded title, HTTPS web URL, normalized lifecycle, base/head branches, exact head revision, check
aggregates, and review aggregates. Unknown provider values may be retained in the bounded
`providerValue`, but host behavior uses the normalized lifecycle. Open and draft requests must
match the requested branch; closed and merged requests must also match the exact HEAD revision.

Provider code calls the host client instead of opening a socket:

```swift
let result = try await ExtensionHostClient().sourceControlFetch(
    ExtensionSourceControlFetchRequest(
        connectionID: request.connectionID,
        path: "/repos/\(owner)/\(repository)/pulls",
        queryItems: [
            .init(name: "state", value: "open"),
            .init(name: "limit", value: "50")
        ]
    )
)
```

Treat every API response as hostile input: decode only the fields needed, cap collections before
retaining them, select the latest check per context and latest review per user, and mark aggregates
incomplete when pagination or a provider cap prevents a complete reading.

## Host consumers and scaling

`ChangeRequestSummaryStore` is the single remote-read path for Git Review and native navigators.
It deduplicates in-flight work per checkout, admits at most four provider pipelines, caches success
for 60 seconds and failure for 15 seconds, and keeps Git and provider I/O off the main actor.

Native plugin API v5 adds `PluginWorkspaceChangeRequest` and
`PluginWorkspaceNavigatorContext.setVisibleItemIdentities`. A navigator reports at most 128 live
session rows; Threading fetches summaries only for those rows and cancels consumers as rows leave
the viewport. Plugins receive no error diagnostics, path, provider response, token, or repository
authority. `openChangeRequest` asks Threading to open only the already validated URL currently
published for that session.

The built-in navigator remains the default and is unchanged. The bundled T3 proof of concept uses
the native design-system components and semantic palette to add lifecycle, checks, and reviews to
its optional custom row. Presentation can vary; local Git truth, provider invocation, credentials,
URL validation, mutations, and navigation stay host-owned.

## Reference implementation

`Packages/ThreadingExtensionKit/Examples/ForgejoSourceControlExtension` is the acceptance example.
It implements Forgejo repository, pull-request, commit-status, and review reads, exact branch/HEAD
matching, bounded JSON decoding, pagination-aware aggregation, and provider-neutral output. Its
manifest asks for only `source-control.read`; it has no static network grant, settings, storage,
session, project, component, or navigator capability.

The corresponding JSON contracts are
`schema/extension-source-control.schema.json`, with request and response envelopes referenced by
`schema/extension-process.schema.json` and provider definitions referenced by
`schema/extension-manifest.schema.json`.
