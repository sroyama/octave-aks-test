# Azure Setup — Octave AKS Dev / Review Cluster

Step-by-step runbook to provision everything in Azure for this Flux GitOps repo.
Fill in the `<...>` placeholders. Names already known from the repo are pre-filled.

Known values:

| Item | Value |
|---|---|
| Entra ID tenant | `96c2c3ba-19d3-47b6-ba0b-8f7471bd1f14` |
| Key Vault URL | `https://octave-aks-test-kv.vault.azure.net/` (vault name `octave-aks-test-kv`) |
| Hostname | `octave-dev.topcon.app` |
| Flux namespace | `oct-gitops-ns` |
| App namespace | `octave` |
| Registries | `acrdev01global-hudngze7h7hcd6gw.azurecr.io` (all images + Helm charts) |

The only repo edit required after this runbook is the `identityId` in
`apps/overlays/dev/azure-key-vault-secret-store.yaml` (tenantId and vaultUrl are already set).

---

## 0. Prerequisites

- Tools: `az` CLI, `kubectl`, `helm`.
- Azure CLI extensions:

```bash
az login
az account set --subscription "<SUBSCRIPTION_ID>"
az extension add --name k8s-configuration
az extension add --name k8s-extension
```

> **Note — use the 64-bit Azure CLI.** On the legacy 32-bit install (path
> `C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\...`), `az extension add --name k8s-extension`
> fails with `Pip failed with status code 1`. Fix it by uninstalling the old CLI and installing
> the current 64-bit build from <https://aka.ms/installazurecli> (or
> `winget install -e --id Microsoft.AzureCLI`), then opening a new terminal. Verify with
> `az version` and `where.exe az` (should resolve under `Program Files`, no `(x86)`).
> If you are behind a corporate proxy, add `--pip-proxy http://<proxy>:<port>` to the
> `az extension add` commands.

- Choose names: resource group `<rg-octave-dev>`, region `<eastus>`, AKS `<aks-octave-dev>`.
- Key Vault name is `octave-aks-test-kv`.

---

## 1. Resource group + AKS cluster

Enable OIDC/workload identity and the monitoring addon (the repo ships `ama-metrics` /
`container-azm` configmaps).

```bash
az group create -n <rg-octave-dev> -l <eastus>

az aks create -g <rg-octave-dev> -n <aks-octave-dev> \
  --node-count 3 --node-vm-size Standard_D4s_v5 \
  --enable-managed-identity \
  --enable-oidc-issuer --enable-workload-identity \
  --enable-addons monitoring \
  --generate-ssh-keys

az aks get-credentials -g <rg-octave-dev> -n <aks-octave-dev>
```

---

## 2. Grant the cluster pull access to the ACR

Image pulls are handled by the **`acrdevglobal-regcred` dockerconfig pull secret**, which
External Secrets syncs from Key Vault (the `acrdevglobal-es` ExternalSecret, step 4) and which
is attached to the `octave` namespace **default ServiceAccount** (`apps/base/default-serviceaccount.yaml`).
This is credential-based, so it works even though the dev ACR is in a **different subscription
and a different Entra tenant** than the cluster — no `--attach-acr` is required.

You only need to provide valid ACR credentials in Key Vault (`acrdevglobal-username` /
`acrdevglobal-password`, step 4). Use an ACR token scoped to pull, or the registry's admin user.

> `--attach-acr` is **not** usable here because it relies on the kubelet managed identity getting
> an `AcrPull` role assignment, which does not work across Entra tenants. If you later add a
> **same-tenant** ACR you *may* attach it with the full resource ID:
> ```bash
> ACR_ID=$(az acr show -n <acr-name> --subscription "<ACR_SUB_ID>" --query id -o tsv)
> az aks update -g <rg-octave-dev> -n <aks-octave-dev> --attach-acr "$ACR_ID"
> ```
> To add another **cross-tenant** registry, create another ExternalSecret producing a
> dockerconfig secret and add its name to the default ServiceAccount's `imagePullSecrets`.

---

## 3. Key Vault + grant the cluster's identity access to it

The repo `SecretStore` uses `authType: ManagedIdentity` with an `identityId`. The simplest
approach (**Option A**) is to reuse the cluster's **kubelet identity**, which is already
assigned to the node-pool VMSS — so External Secrets pods can obtain its token via IMDS with no
extra assignment. You only need to grant it Key Vault read access.

This uses a **Key Vault access policy** rather than an RBAC role assignment. Setting an access
policy only needs `Microsoft.KeyVault/vaults/write` (included in **Contributor**), so you do
**not** need the Owner / RBAC-administrator rights that `az role assignment create` requires.

```bash
# Key Vault in access-policy mode.
# Create it this way, OR if it already exists in RBAC mode, switch it:
az keyvault create -g <rg-octave-dev> -n octave-aks-test-kv \
  --enable-rbac-authorization false
# (existing RBAC-mode vault) -> az keyvault update -n octave-aks-test-kv --enable-rbac-authorization false

# Reuse the cluster's kubelet identity
KUBELET_CLIENT_ID=$(az aks show -g <rg-octave-dev> -n <aks-octave-dev> \
  --query identityProfile.kubeletidentity.clientId -o tsv)
KUBELET_OBJ=$(az aks show -g <rg-octave-dev> -n <aks-octave-dev> \
  --query identityProfile.kubeletidentity.objectId -o tsv)

# Grant it read on the vault's secrets via an access policy
az keyvault set-policy -n octave-aks-test-kv \
  --object-id $KUBELET_OBJ --secret-permissions get list

echo "Set this as identityId in apps/overlays/dev/azure-key-vault-secret-store.yaml:"
echo $KUBELET_CLIENT_ID
```

> **Note on auth modes:** `authType: ManagedIdentity` in the `SecretStore` only controls *how*
> External Secrets authenticates (IMDS token for the kubelet identity). *Authorization* is then
> handled by whichever vault mode you chose — access policy here. Both work with the same
> `identityId`; no manifest change is needed.

<details>
<summary><b>Alternative — RBAC role assignment (needs Owner / RBAC Administrator)</b></summary>

If you have the **Role Based Access Control Administrator** or **Owner** role, keep the vault in
RBAC mode (`--enable-rbac-authorization true`) and grant access with a role assignment instead:

```bash
KV_ID=$(az keyvault show -n octave-aks-test-kv --query id -o tsv)
az role assignment create --assignee-object-id $KUBELET_OBJ \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" --scope $KV_ID
```

Plain **Contributor** cannot do this — it fails with `AuthorizationFailed` on
`Microsoft.Authorization/roleAssignments/write`.
</details>

Then edit **`apps/overlays/dev/azure-key-vault-secret-store.yaml`**:

- `identityId:` → value of `$KUBELET_CLIENT_ID` (a clientId GUID generated by Azure — not hand-made)
- `tenantId:` → `e7b9da96-8bec-436c-85e7-d92b2d7d1c1f` (already set)
- `vaultUrl:` → `https://octave-aks-test-kv.vault.azure.net/` (already set)

<details>
<summary><b>Option B — dedicated user-assigned identity (more isolation, more steps)</b></summary>

Instead of the kubelet identity, create a separate identity, grant it Key Vault read, and
assign it to the node-pool VMSS so IMDS can issue its token:

```bash
az identity create -g <rg-octave-dev> -n <id-octave-dev-eso>
ESO_CLIENT_ID=$(az identity show -g <rg-octave-dev> -n <id-octave-dev-eso> --query clientId -o tsv)
ESO_PRINCIPAL=$(az identity show -g <rg-octave-dev> -n <id-octave-dev-eso> --query principalId -o tsv)

az role assignment create --assignee-object-id $ESO_PRINCIPAL \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" --scope $KV_ID

NODE_RG=$(az aks show -g <rg-octave-dev> -n <aks-octave-dev> --query nodeResourceGroup -o tsv)
VMSS=$(az vmss list -g $NODE_RG --query "[0].name" -o tsv)
ID_RES=$(az identity show -g <rg-octave-dev> -n <id-octave-dev-eso> --query id -o tsv)
az vmss identity assign -g $NODE_RG -n $VMSS --identities $ID_RES

# Use $ESO_CLIENT_ID as identityId instead of the kubelet clientId.
```
</details>

---

## 4. Populate Key Vault secrets

Each `ExternalSecret` reads `secret/<name>`, so the Key Vault secret name is the part after
`secret/`. Create all of these:

```bash
KV=octave-aks-test-kv

# Registry pull creds for the GLOBAL ACR (-> acrdevglobal-regcred)
az keyvault secret set --vault-name $KV -n acrdevglobal-username --value "<acr_username>"
az keyvault secret set --vault-name $KV -n acrdevglobal-password --value "<acr_password>"

# oauth2-proxy (Azure Enterprise App — see step 5)
az keyvault secret set --vault-name $KV -n oauth-client-id     --value "<app_client_id>"
az keyvault secret set --vault-name $KV -n oauth-client-secret --value "<app_client_secret>"
az keyvault secret set --vault-name $KV -n oauth-cookie-secret --value "$(openssl rand -base64 32 | head -c 32)"
# PowerShell (no openssl): generate a 32-byte cookie secret
# az keyvault secret set --vault-name $KV -n oauth-cookie-secret --value ([Convert]::ToBase64String((1..32 | ForEach-Object {Get-Random -Max 256}) -as [byte[]]).Substring(0,32))

# Keycloak
az keyvault secret set --vault-name $KV -n keycloak-ADMIN-USERNAME             --value "admin"
az keyvault secret set --vault-name $KV -n keycloak-ADMIN-PASSWORD             --value "<strong_pw>"
az keyvault secret set --vault-name $KV -n keycloak-DB-PASSWORD                --value "<strong_pw>"
az keyvault secret set --vault-name $KV -n keycloak-mssql-SA-PASSWORD          --value "<Strong#Pw1>"
az keyvault secret set --vault-name $KV -n keycloak-CLIENT-WEBAPI-SECRET       --value "<secret>"
az keyvault secret set --vault-name $KV -n keycloak-CDSS-HARMONY-CLIENT-SECRET --value "<secret>"
az keyvault secret set --vault-name $KV -n keycloak-CDSS-DDSS-CLIENT-SECRET    --value "<secret>"
az keyvault secret set --vault-name $KV -n keycloak-JOBQUEUE-DDSS-CLIENT-SECRET --value "<secret>"

# PACS (dcm4chee arc + postgres)
az keyvault secret set --vault-name $KV -n pacs-arc-POSTGRES-USER             --value "pacs"
az keyvault secret set --vault-name $KV -n pacs-arc-POSTGRES-PASSWORD         --value "<strong_pw>"
az keyvault secret set --vault-name $KV -n pacs-arc-WILDFLY-ADMIN-USER        --value "admin"
az keyvault secret set --vault-name $KV -n pacs-arc-WILDFLY-ADMIN-PASSWORD    --value "<strong_pw>"
az keyvault secret set --vault-name $KV -n pacs-pg-POSTGRES-USER              --value "pacs"
az keyvault secret set --vault-name $KV -n pacs-pg-POSTGRES-PASSWORD          --value "<strong_pw>"
```

> MongoDB uses an in-cluster, no-auth connection string baked into the manifests — no Key
> Vault secret is required for it.

**Full list of required Key Vault secret names:**

```
acrdevglobal-username, acrdevglobal-password,
oauth-client-id, oauth-client-secret, oauth-cookie-secret,
keycloak-ADMIN-USERNAME, keycloak-ADMIN-PASSWORD, keycloak-DB-PASSWORD,
keycloak-mssql-SA-PASSWORD, keycloak-CLIENT-WEBAPI-SECRET,
keycloak-CDSS-HARMONY-CLIENT-SECRET, keycloak-CDSS-DDSS-CLIENT-SECRET,
keycloak-JOBQUEUE-DDSS-CLIENT-SECRET,
pacs-arc-POSTGRES-USER, pacs-arc-POSTGRES-PASSWORD,
pacs-arc-WILDFLY-ADMIN-USER, pacs-arc-WILDFLY-ADMIN-PASSWORD,
pacs-pg-POSTGRES-USER, pacs-pg-POSTGRES-PASSWORD,
Topconapp2025 (certificate — see step 6)
```

---

## 5. Register the Azure Enterprise Application (oauth2-proxy)

1. Entra ID → **App registrations** → New registration (e.g. `octave-dev`), in tenant
   `96c2c3ba-19d3-47b6-ba0b-8f7471bd1f14`.
2. Redirect URI (type **Web**): `https://octave-dev.topcon.app/oauth2/callback`
3. Copy **Application (client) ID** → Key Vault `oauth-client-id`.
4. **Certificates & secrets** → New client secret → copy value → Key Vault `oauth-client-secret`.
5. **Token configuration** → add optional claim `email`. Access is restricted to `topcon.com`
   accounts by `OAUTH2_PROXY_EMAIL_DOMAINS=topcon.com`.

The oauth2-proxy config (`apps/base/oauth2-proxy/kustomization.yaml`) already points its OIDC
issuer / tenant at `96c2c3ba-19d3-47b6-ba0b-8f7471bd1f14`.

---

## 6. TLS certificate for `octave-dev.topcon.app`

The `tls-es` ExternalSecret expects a Key Vault **certificate** named `Topconapp2025`. Its SAN
must cover `octave-dev.topcon.app` (a `*.topcon.app` wildcard works).

```bash
az keyvault certificate import --vault-name octave-aks-test-kv \
  -n Topconapp2025 -f <path-to.pfx> --password "<pfx_password>"
```

---

## 7. Push this repo to Git

```bash
cd C:\Topcon\octave\octave-aks-test
git init && git add . && git commit -m "Octave AKS dev cluster (Flux)"
git remote add origin <YOUR_GIT_URL>
git push -u origin main
```

---

## 8. Install Flux + wire the two Kustomizations (Azure GitOps)

`apps` depends on `infrastructure`; both reconcile into `oct-gitops-ns`.

```bash
az k8s-configuration flux create \
  -g <rg-octave-dev> -c <aks-octave-dev> --cluster-type managedClusters \
  -n octave-dev \
  --namespace oct-gitops-ns \
  --scope cluster \
  --url <YOUR_GIT_URL> --branch main \
  --kustomization name=infrastructure path=./infrastructure prune=true \
  --kustomization name=apps path=./apps/overlays/dev prune=true dependsOn=["infrastructure"]
```

This installs the Flux (`microsoft.flux`) extension automatically if it's not present.

---

## 9. Point DNS at the HAProxy load balancer

After `infrastructure` reconciles, read the external IP and create the DNS A record
`octave-dev.topcon.app → <IP>`:

```bash
kubectl get svc -n oct-gitops-ns haproxy-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

For a static IP, pre-create a public IP in the node resource group and set
`controller.service.loadBalancerIP` in `infrastructure/haproxy-ingress/helmrelease.yaml`.

---

## 10. Verify

```bash
# Flux + reconciliation
az k8s-configuration flux show -g <rg-octave-dev> -c <aks-octave-dev> \
  --cluster-type managedClusters -n octave-dev
kubectl get helmrelease,kustomization -A

# External Secrets resolved (SecretSynced=True)
kubectl get externalsecret -n octave
kubectl get secret -n octave   # acrdevglobal-regcred, octave-topconapp-tls, oauth2-proxy-secret, ...

# Workloads + ingress
kubectl get pods -n octave
kubectl get ingress -n octave  # 5 ingresses, host octave-dev.topcon.app

# End-to-end: browse https://octave-dev.topcon.app/octave
#   -> redirects to Microsoft login, accepts only @topcon.com, then loads the Octave client.
```

---

## Order summary

RG/AKS → attach ACRs → Key Vault + identity (set `identityId` in the overlay) → KV secrets →
Enterprise App → TLS cert → push repo → Flux create → DNS → verify.
