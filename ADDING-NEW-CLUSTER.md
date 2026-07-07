# Adding a New Cluster Overlay

This document explains how to create a new Kustomize overlay for a new AKS
cluster (e.g. `overlays/test`). The `apps/base/` layer contains no
cluster-specific values; everything that varies per cluster lives entirely
inside the overlay folder.

---

## What "base" contains vs. what "overlays" own

| Category | Base value (placeholder) | Owned by overlay |
|---|---|---|
| Public hostname | `octave.example.com` | Yes — injected via patches |
| auth-signin annotation URLs | `https://octave.example.com/…` | Yes — injected via patches |
| `OCTAVE_API_URL` env var | `https://octave.example.com/octave` | Yes — injected via patches |
| `OAUTH2_PROXY_REDIRECT_URL` | `https://octave.example.com/…` | Yes — injected via patches |
| `harmony-ui-mock` config.json | *(not in base at all)* | Yes — provided as a file |
| Azure Key Vault SecretStore | *(not in base)* | Yes — `azure-key-vault-secret-store.yaml` |
| TLS secret key-vault cert name | `secret/Topconapp2025` | Only if a different cert is used |
| ACR registry URL | `acrdev01global-…azurecr.io` | Only if a different ACR is used |
| Azure AD tenant ID | `96c2c3ba-…` (in oauth2-proxy) | Only if a different AAD tenant is used |

---

## Step-by-step: create `overlays/test`

### 1. Create the overlay directory

```
apps/
  overlays/
    test/        ← create this
```

### 2. Create `azure-key-vault-secret-store.yaml`

Copy from `overlays/dev/azure-key-vault-secret-store.yaml` and replace the
three test-cluster-specific values:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: azure-key-vault-secret-store
  namespace: octave
spec:
  provider:
    azurekv:
      authType: ManagedIdentity
      identityId: "<test-cluster-kubelet-managed-identity-client-id>"
      tenantId: "<azure-ad-tenant-id>"
      vaultUrl: "https://<test-key-vault-name>.vault.azure.net/"
```

To find the kubelet identity client ID:
```sh
az aks show -g <resource-group> -n <cluster-name> \
  --query identityProfile.kubeletidentity.clientId -o tsv
```

### 3. Create `harmony-ui-mock-config.json`

This file is served directly to the browser so every URL must use the real
test hostname:

```json
{
  "harmonyApiUrl": "https://my-test.something.app/harmony/api/v2",
  "octaveUrlBase": "https://my-test.something.app/octave/",
  "patientApiUrl": "https://my-test.something.app/harmony/api/v2/patients",
  "authority": "http://not-used-in-aks:8088/realms/docker-octave-realm",
  "clientId": "octave-harmony-ui-mock",
  "redirectUri": "https://my-test.something.app/",
  "enableAuth": false
}
```

### 4. Create `kustomization.yaml`

This is the main file. Copy the template below and replace every occurrence of
`my-test.something.app` with your real test hostname.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

commonAnnotations:
  octave-overlay: test

resources:
  - ../../base
  - azure-key-vault-secret-store.yaml

# ---------------------------------------------------------------------------
# harmony-ui-mock config.json (cluster-specific because it embeds the hostname)
# ---------------------------------------------------------------------------
configMapGenerator:
- name: harmony-ui-mock-config
  files:
  - config.json=harmony-ui-mock-config.json

# ---------------------------------------------------------------------------
# Hostname patches — replace "octave.example.com" placeholder from base
# with this cluster's real public hostname in every affected resource.
# ---------------------------------------------------------------------------
patches:
  # --- Ingress: host + TLS + auth-signin annotation ---
  - target:
      kind: Ingress
      name: octave-client-ingress
    patch: |
      - op: replace
        path: /metadata/annotations/haproxy-ingress.github.io~1auth-signin
        value: "https://my-test.something.app/oauth2/start?rd=%[path]"
      - op: replace
        path: /spec/rules/0/host
        value: my-test.something.app
      - op: replace
        path: /spec/tls/0/hosts/0
        value: my-test.something.app

  - target:
      kind: Ingress
      name: octave-webapi-ingress
    patch: |
      - op: replace
        path: /metadata/annotations/haproxy-ingress.github.io~1auth-signin
        value: "https://my-test.something.app/oauth2/start?rd=%[path]"
      - op: replace
        path: /spec/rules/0/host
        value: my-test.something.app
      - op: replace
        path: /spec/tls/0/hosts/0
        value: my-test.something.app

  - target:
      kind: Ingress
      name: harmony-ui-mock-ingress
    patch: |
      - op: replace
        path: /metadata/annotations/haproxy-ingress.github.io~1auth-signin
        value: "https://my-test.something.app/oauth2/start?rd=%[path]"
      - op: replace
        path: /spec/rules/0/host
        value: my-test.something.app
      - op: replace
        path: /spec/tls/0/hosts/0
        value: my-test.something.app

  - target:
      kind: Ingress
      name: oauth2-proxy-ingress
    patch: |
      - op: replace
        path: /spec/rules/0/host
        value: my-test.something.app
      - op: replace
        path: /spec/tls/0/hosts/0
        value: my-test.something.app

  - target:
      kind: Ingress
      name: dotnet-harmony-api-mock-fileservice-ingress
    patch: |
      - op: replace
        path: /spec/rules/0/host
        value: my-test.something.app
      - op: replace
        path: /spec/tls/0/hosts/0
        value: my-test.something.app

  # --- ConfigMap: oauth2-proxy redirect URL ---
  - target:
      kind: ConfigMap
      name: oauth2-proxy-config
    patch: |
      - op: replace
        path: /data/OAUTH2_PROXY_REDIRECT_URL
        value: "https://my-test.something.app/oauth2/callback"

  # --- Deployment: octave-client API URL env var ---
  - target:
      kind: Deployment
      name: octave-client
    patch: |
      - op: replace
        path: /spec/template/spec/containers/0/env/0/value
        value: "https://my-test.something.app/octave"
```

### 5. Register the Keycloak OAuth2 redirect URI

The new hostname must be registered as a valid redirect URI in the Azure AD
app registration that backs `oauth2-proxy`.  Add:

```
https://my-test.something.app/oauth2/callback
```

### 6. Provision the TLS certificate

By default the overlay reuses the same TLS ExternalSecret from base
(`tls-es.yaml`), which pulls the certificate named `secret/Topconapp2025`
from Key Vault and creates a Kubernetes secret called `octave-topconapp-tls`.

**If the test cluster uses the same wildcard certificate** — no changes needed.

**If the test cluster needs its own certificate**, add the cert to Key Vault
and patch two things in your overlay:

```yaml
# Patch tls-es.yaml to pull a different cert from Key Vault
- target:
    kind: ExternalSecret
    name: octave-topconapp-tls-es
  patch: |
    - op: replace
      path: /spec/data/0/remoteRef/key
      value: secret/MyTestCert2025
    - op: replace
      path: /spec/target/name
      value: my-test-tls

# Patch every Ingress to reference the new TLS secret name
- target:
    kind: Ingress
  patch: |
    - op: replace
      path: /spec/tls/0/secretName
      value: my-test-tls
```

---

## Optional: use a different ACR registry

If the test cluster pulls images from a different Azure Container Registry,
use the `images:` field to remap every image without touching base:

```yaml
# In overlays/test/kustomization.yaml
images:
  - name: acrdev01global-hudngze7h7hcd6gw.azurecr.io/octave/octave-client-web
    newName: acrtestXXXXXX.azurecr.io/octave/octave-client-web
  - name: acrdev01global-hudngze7h7hcd6gw.azurecr.io/octave/harmony-ui-mock
    newName: acrtestXXXXXX.azurecr.io/octave/harmony-ui-mock
  # ... one entry per image found in base deployments
```

Also patch `helm-repository.yaml` and `acrdevglobal-es.yaml` if they must
point to the new ACR.

---

## Resulting folder structure

```
apps/
  base/                          ← no cluster-specific values; never changes
  overlays/
    dev/
      kustomization.yaml
      azure-key-vault-secret-store.yaml
      harmony-ui-mock-config.json
    test/                        ← new cluster; mirrors dev structure
      kustomization.yaml
      azure-key-vault-secret-store.yaml
      harmony-ui-mock-config.json
```

## Verification

After creating the overlay, dry-run the build locally to confirm the
placeholder is fully replaced before committing:

```sh
kustomize build apps/overlays/test | grep "octave.example.com"
# Should return no output — zero placeholder leaks.

kustomize build apps/overlays/test | grep "my-test.something.app"
# Should list every Ingress host, annotation URL, OAUTH2 redirect, and OCTAVE_API_URL.
```
