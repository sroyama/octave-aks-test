# Octave AKS — Dev / Review Cluster (Flux GitOps)

This repository contains the Flux GitOps configuration that deploys the **Octave web
application** to an AKS cluster used for **development and internal review**.

It is derived from the local Docker Compose (`octave-docker/octave-local-compose`) and reuses
the Flux infrastructure pattern from the performance-testing cluster (`octave-perf-aks`). This
cluster prioritizes **being easy to change and update over performance**.

## Repository structure

```
apps/
  base/                 # Environment-agnostic Kubernetes manifests for every service
  overlays/
    dev/                # The dev/review overlay (Key Vault SecretStore, image pins)
infrastructure/         # Cluster-wide infrastructure (External Secrets, HAProxy ingress, logging)
```

Flux applies `infrastructure/` first, then `apps/overlays/dev/` (which `dependsOn` the
infrastructure). See **Flux bootstrap** below.

## What runs here

All services from `octave-local-compose` are deployed **except**:

- `reverse-proxy` (Traefik) — replaced by the AKS **HAProxy ingress**.
- `octave-pixelsmart-webapi-old` — explicitly excluded.

Services brought over (cluster-internal unless noted):

| Area | Services |
|---|---|
| Octave APIs | octave-webapi, octave-rdb-webapi, octave-shadowgram-webapi, octave-pixelsmartq-webapi, octave-pixelsmart-generation-webapi, octave-appdata-webapi, octave-fdaparser-webapi |
| UI | octave-client, harmony-ui-mock |
| Mocks (.NET, from compose) | dotnet-harmony-api-mock, ddss-api-mock |
| Supporting | keycloak (+mssql), pacs (arc/ldap/pg), mongodb, activemq-artemis (+artemis-proxy) |
| Jobs | import-dcm-files |
| Auth | oauth2-proxy |

> Note: the harmony/DDSS mocks are the **real .NET mocks** from the compose
> (`octave-mockharmonyapi-webapi`, `octave-mockddss-webapi`), not the generic `mockserver`
> used by the perf cluster, because the spec requires exposing `dotnet-harmony-api-mock`.

## Ingress & authentication

- **HAProxy ingress controller** (chart `haproxy-ingress/haproxy-ingress`, controller
  `haproxy-ingress.github.io/controller`, IngressClass `haproxy`) replaces `ingress-nginx`.
- Only **four** services are exposed to the Internet, all under `https://octave-dev.topcon.app`:
  1. `octave-client`            → `/octave`
  2. `octave-webapi`            → `/octave/api` (rewritten to `/api`)
  3. `harmony-ui-mock`          → `/`
  4. `dotnet-harmony-api-mock`  → `/harmony`
- All exposed ingresses require authentication via **oauth2-proxy** using HAProxy's
  external-auth annotations:
  - `haproxy-ingress.github.io/auth-url`
  - `haproxy-ingress.github.io/auth-signin`
  - `haproxy-ingress.github.io/auth-headers-succeed`
- oauth2-proxy uses the **Azure (Entra ID)** provider and restricts access to **topcon.com**
  accounts (`OAUTH2_PROXY_EMAIL_DOMAINS=topcon.com`). The web app must be registered as an
  Azure **Enterprise Application** with redirect URI
  `https://octave-dev.topcon.app/oauth2/callback`.

## Secrets — nothing sensitive in this repo

All credentials (registry pull secret, TLS cert, oauth2 client id/secret/cookie secret,
keycloak/db secrets) are pulled at runtime from **Azure Key Vault** via the **External Secrets
Operator**. The repo only contains non-secret IDs/URLs.

Configure the dev environment in `apps/overlays/dev/azure-key-vault-secret-store.yaml`:

- `identityId`  — the dev cluster's managed-identity client id
- `tenantId`    — Entra ID tenant id
- `vaultUrl`    — the dev Key Vault URL

Required Key Vault secrets (referenced by the `ExternalSecret` resources):
`Topconapp2025` (TLS pfx), `acrdevglobal-username`, `acrdevglobal-password`,
`oauth-client-id`, `oauth-client-secret`, `oauth-cookie-secret`, plus the keycloak/pacs
secrets inherited from the base manifests.

## Flux bootstrap

This cluster is managed by **Azure GitOps (Flux configuration on AKS)**. Create two Flux
Kustomizations pointing at this repo:

1. `infrastructure` → path `./infrastructure`
2. `apps` → path `./apps/overlays/dev`, with `dependsOn: [infrastructure]`

The `apps` Kustomization depends on the infrastructure one because it relies on the External
Secrets CRDs and the HAProxy ingress controller being present.

## Local validation

```powershell
kubectl kustomize infrastructure
kubectl kustomize apps/base
kubectl kustomize apps/overlays/dev
```

All three should render without errors.

## Known divergences / follow-ups

- `octave-appdata-webapi`, `dotnet-harmony-api-mock` and `ddss-api-mock` all share the single
  standalone `mongodb` service (databases `octaveAppDB`, `mockHarmony`, `mockDdss`
  respectively). The appdata connection string is now an in-cluster, non-secret value, so its
  former Key Vault `ExternalSecret` was removed.
- `mongodb` runs as a single standalone node (no replica set) for simplicity; revisit if
  transactions/replica-set behavior is needed.
- Base manifests use `:latest` image tags for easy updates. Pin reproducible tags in
  `apps/overlays/dev/kustomization.yaml` (`images:`) when a frozen build is required.
- HAProxy external-auth annotation values should be confirmed against the deployed
  haproxy-ingress chart version.
