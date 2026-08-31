# Operated development control plane

This is a separate Cloudflare state and data plane for physical-device development testing. It
owns only the development D1 database and the path-scoped Access application. Wrangler separately
owns the development Worker, Durable Object, custom domain, rate-limit bindings and daily cleanup.
It shares no D1, Worker credential, Keychain account, or rate-limit namespace with production.

Access covers exactly:

`dev.remote.threading.codes/v1/auth/development/authorize`

The public native API is not placed behind an Access cookie. Browser authorization requires an
exact-email Allow policy, and the Worker cryptographically validates the resulting Access JWT,
its issuer, application audience and the same exact email list before it authorizes a transaction.

## Account-specific files

Copy `terraform.tfvars.example` to the ignored `terraform.tfvars`. Set the Cloudflare account ID,
the existing Zero Trust team domain, and one to eight exact lowercase email addresses. The API
token in `CLOUDFLARE_API_TOKEN` needs D1 and Access Apps and Policies write permissions.

Create an ignored `backend.hcl` for the protected R2 state backend. It may use the same state
bucket and endpoint as production, but **must use a different key**, for example
`threading/control-plane-development.tfstate`. As with production, R2 S3 credentials belong only
in `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.

Initialize and apply from `Service/ThreadingControlPlane`:

```sh
tofu -chdir=infra/development init -backend-config=backend.hcl
THREADING_INFRA_CLI=tofu npm run infra:development:plan
THREADING_INFRA_CLI=tofu npm run infra:development:apply
```

The saved plan is deliberately separate from production. Inspect it before applying; it should
create an isolated D1 database and one path-scoped Access application with exact-email includes.

## Worker secrets and deploy

The development Worker needs seven secrets: independent random values for
`SESSION_SIGNING_SECRET` and `PUSH_TOKEN_ENCRYPTION_SECRET`, plus the APNs team/key/private key and
Cloudflare TURN key/token already intended for development use. A single unrestricted APNs `.p8`
can sign for both sandbox and production endpoints; the development app registers a sandbox token.

For the first deploy, pass a temporary mode-0600 `KEY=value` file via
`THREADING_DEPLOY_SECRETS_FILE`. Do not commit it. Subsequent deploys preserve installed secrets:

```sh
THREADING_INFRA_CLI=tofu \
THREADING_DEPLOY_SECRETS_FILE=/absolute/path/to/development-secrets \
npm run deploy:development
```

Run a Debug Mac with:

```sh
THREADING_CONTROL_PLANE_URL=https://dev.remote.threading.codes
```

Starting Remote Access opens the protected browser callback. After an allowed identity signs in,
the app redeems the one-time, host-bound transaction and keeps its 24-hour development credential
in a Keychain account separate from production. Pair the physical iPhone normally; after granting
notification permission, it registers its APNs token directly with the Worker using its scoped
device credential. No token copying is part of the test path.
