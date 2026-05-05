# Secrets required in the target namespace

All secrets below must exist in the namespace where the PipelineRuns execute.

## Automatically created

| Secret | Created by | Purpose |
|---|---|---|
| `{{ git_auth_secret }}` | Pipelines as Code | Git clone/push credentials, provisioned automatically per PipelineRun |

## Must be provisioned manually

### `rox-api-token`

- **Type:** Opaque
- **Used by:** `acs-image-check`, `acs-image-scan`, `acs-deploy-check` tasks
- **Keys:**
  - `rox-api-endpoint` — StackRox/ACS Central endpoint (e.g. `rox.stackrox.io:443`)
  - `rox-api-token` — API token with CI permissions
- **Impact if missing:** ACS tasks print a TODO message and skip checks (non-fatal)

### `tpa-secret`

- **Type:** Opaque
- **Used by:** `upload-sbom-to-trustification` task
- **Keys:**
  - `bombastic_api_url` — Trustification Bombastic API URL
  - `oidc_issuer_url` — OIDC issuer URL
  - `oidc_client_id` — OIDC client ID
  - `oidc_client_secret` — OIDC client secret
  - `supported_cyclonedx_version` (optional) — CycloneDX version filter
- **Impact if missing:** Controlled by `fail-if-trustification-not-configured` pipeline param (default `true`, will fail)

### `cosign-pub`

- **Type:** Opaque
- **Used by:** `verify-enterprise-contract` task (promote pipelines)
- **Keys:**
  - `cosign.pub` — Cosign public key for image signature verification
- **Referenced as:** `k8s://<namespace>/cosign-pub`
- **Impact if missing:** Enterprise Contract verification fails

### `tssc-image-registry-auth`

- **Type:** `kubernetes.io/dockerconfigjson`
- **Used by:** `buildah-rhtap`, `init`, `skopeo-copy` tasks (via pipeline SA)
- **Keys:**
  - `.dockerconfigjson` — Docker registry credentials for the image registry
- **Setup:** Must be linked to the `pipeline` ServiceAccount under both `secrets` and `imagePullSecrets`
- **Impact if missing:** Image push/pull/inspect operations fail with authentication errors

### `tas-secret`

- **Type:** Opaque
- **Used by:** `verify-commit` task (indirectly, via TAS service URLs)
- **Keys:**
  - `rekor_url` — Rekor transparency log URL
  - `tuf_url` — TUF mirror URL
- **Impact if missing:** Low risk; the `verify-commit` task has hardcoded default URLs and is gated behind a `when` clause (`verify-commit` param defaults to `false`)
