## ApeiroRA Showroom Infra & Worker Cluster Setup

### Table of Contents

**Basics**
- [Prerequisites](#prerequisites)

**Bootstrap Infra Cluster**
1. [Create the Infra Cluster (Gardener Shoot)](#1-create-the-infra-cluster-gardener-shoot)
2. [Install Flux on Infra Cluster](#2-install-flux-on-infra-cluster)
3. [Apply Infra Cluster Manifests](#3-apply-infra-cluster-manifests)
4. [Add SOPS Age Key Secret](#4-add-sops-age-key-secret)
5. [Encrypt Any New Secrets](#5-encrypt-any-new-secrets)
6. [Verify Test Secret Decryption](#6-verify-test-secret-decryption)
7. [Apply Structured Authentication ConfigMap (Issuer)](#7-apply-structured-authentication-configmap-issuer)

**Worker Cluster**
8. [Create Worker Cluster (Structured Auth Enabled)](#8-create-worker-cluster-shoot-with-structured-auth-enabled)
9. [Provide Cluster CA of Worker to Infra](#9-provide-cluster-ca-of-worker-to-infra-if-remote-sync-needed)
10. [Apply RBAC on Worker Cluster](#10-apply-rbac-on-worker-cluster)
11. [Deploy Worker Cluster Workloads with Infra Flux](#11-deploy-worker-cluster-workloads-via-infra-flux)
12. [Validate Remote Secrets & Namespaces](#12-validate-remote-secrets--namespaces)

**Local Dev Workflow**
13. [Encryption / Decryption Workflow](#13-encryption--decryption-local-workflow)
14. [AGE Key Rotation](#14-age-key-rotation)

**Cross-Cluster Secret Sync (Infra -> Worker)**
15. [Overview Section](#15-cross-cluster-secret-sync-infra---worker)
  - [ESO Release Values](#150-eso-release)
  - [Flow Overview](#151-flow-overview)
  - [Remote Secret Kustomization Example](#152-minimal-remote-secret-kustomization-example)
  - [Kubeconfig Secret](#153-kubeconfig-secret)
  - [Namespace Presence](#154-namespace-presence)
  - [RBAC for Remote Sync & ESO](#155-rbac-for-remote-sync--eso)
  - [ESO Notes](#156-external-secrets-operator-eso-notes)
  - [Troubleshooting](#157-troubleshooting-remote-secret-delivery)
  - [Verification Commands](#158-verification-commands)
  - [Hardening](#159-recommended-hardening)

**External Secrets Linkerd CA Sync**
16. [Linkerd CA Sync Section](#16-external-secrets-cross-cluster-linkerd-ca-sync)
  - [Goal](#161-goal)
  - [Components](#162-components)
  - [ClusterSecretStore Example](#163-clustersecretstore-example)
  - [ExternalSecret Definition](#164-externalsecret-definition)
  - [RBAC Requirements](#165-rbac-requirements-worker-cluster)
  - [Token / Auth Considerations](#166-token--auth-considerations)
  - [Validation Steps](#167-validation-steps)

This document complements the root `README.md` with the concrete step‑by‑step for bootstrapping the Infra (control) cluster and a Worker cluster using Flux, SOPS (age), and Kubernetes structuredAuthentication.

### Prerequisites
* Access to the Gardener project (create shoots, view project namespaces).
* `kubectl` configured for the Infra cluster (and later the Worker cluster).
* `flux` CLI installed (`brew install fluxcd/tap/flux`).
* `age` and `sops` installed (`brew install age sops`).
* The shared `age.agekey` file (retrieve from secure vault if you don't already have it). Place it at repository root (`./age.agekey`). It is ignored by Git.
* Git pre‑commit hook enabled (see root `README.md` Git Hook section).

### 1. Create the Infra Cluster (Gardener Shoot)
Enable required extensions when creating the shoot (YAML excerpt):
```yaml
  extensions:
    - type: shoot-dns-service
      providerConfig:
        apiVersion: service.dns.extensions.gardener.cloud/v1alpha1
        kind: DNSConfig
        syncProvidersFromShootSpecDNS: true
```
```yaml
  annotations:
    authentication.gardener.cloud/issuer: managed
```
`showroominfra-issuer-configmap` enables structuredAuthentication username prefixing.

Choose Machine Type:

```yaml
  machine:
    type: g_c8_m16
    image:
      name: gardenlinux
      version: 1877.4.0
```

### 2. Install Flux on Infra Cluster
```bash
flux install --namespace=flux-system
kubectl -n flux-system get deployments,pods
```

### 3. Apply Infra Cluster Manifests
```bash
kubectl apply -k ./environments/production/infra/cluster/
```

### 4. Add SOPS Age Key Secret
If you do not have `age.agekey` locally. Get it from the old Cluster or create a new one and rotate the pubkey in .sops.yaml

```bash
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=./age.agekey
```
Flux Kustomizations referencing `spec.decryption.secretRef.name: sops-age` will now decrypt encrypted Secrets.

### 5. Encrypt Any New Secrets
Create or edit plain Secret manifests only briefly, then run:
```bash
make encrypt-secrets
```
Verify encryption:
```bash
grep -R "ENC[" environments/ | head
```
Pre-commit will block if a staged file in a `secrets/` path still has plaintext `stringData` without SOPS metadata.

### 6. Verify Test Secret Decryption
After Flux reconciliation:
```bash
flux get kustomizations
kubectl get secret <test-secret-name> -n <namespace>
```
The cluster Secret will show binary `data` (decoded by the API server on request). The Git version remains encrypted.

### 7. Apply Structured Authentication ConfigMap (Issuer)
Check if ConfigMap exists (Gardener project namespace e.g. `garden-kms`):
```bash
kubectl get cm showroominfra-issuer-configmap -n garden-kms
```
If absent:
```bash
# Create the structured authentication issuer ConfigMap (example)
kubectl apply -f setup/issuer-config-map.yaml -n garden-kms

# Confirm
kubectl get cm showroominfra-issuer-configmap -n garden-kms -o yaml | grep -E 'usernamePrefix|issuer'
```

### 8. Create Worker Cluster (structuredAuthentication)
Create the Worker shoot similarly (choose smaller machine type if appropriate) and ensure structured authentication is enabled. Example Gardener shoot snippet:
```yaml
metadata:
  annotations:
    authentication.gardener.cloud/issuer: managed
spec:
  extensions:
    - type: shoot-dns-service
  provider: aws   # or azure/gcp/openstack etc.
```
After creation obtain kubeconfig:
```bash
kubectl get secret <worker-shoot-kubeconfig-secret> -n garden-kms -o jsonpath='{.data.kubeconfig}' | base64 -d > worker01.kubeconfig
```
Validate access:
```bash
KUBECONFIG=worker01.kubeconfig kubectl get nodes
```

### 9. Provide Cluster CA of Worker to Infra (if remote sync needed)
If you plan to apply manifests to the Worker from Infra using Flux `spec.kubeConfig`, ensure the Infra repo (and optionally cluster) has the Worker CA:
```bash
grep 'certificate-authority-data' worker01.kubeconfig | awk -F': ' '{print $2}' > worker01.ca.b64
base64 -d worker01.ca.b64 > worker01.ca.crt
```
Store it securely (e.g. SOPS‑encrypted Secret manifest) if committing:
```bash
cat > environments/production/workers/worker01/cluster/secrets/worker01-ca-secret.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: worker01-ca
  namespace: flux-system
stringData:
  ca.crt: |
    # paste PEM from worker01.ca.crt
EOF
make encrypt-secrets
```
Or embed CA directly in the kubeconfig you create as a Secret (recommended):
```bash
kubectl -n flux-system create secret generic kubeconfig --from-file=value.yaml=worker01.kubeconfig
```

### 10. Apply RBAC on Worker Cluster
Pre-create Roles and RoleBindings on the Worker cluster so the Infra Flux controllers (via OIDC subject prefix) and any dedicated remote sync ServiceAccounts have least privilege access.
```bash
KUBECONFIG=worker01.kubeconfig kubectl apply -f setup/rbac.yaml
```
Key points:
* Role names ending in `-secrets-read` grant `get,list,watch` on Secrets only.
* Bindings include subjects with and without the username prefix (`infra-cluster-oidc:`) to handle API server differences.
* Avoid granting cluster-admin unless required for bootstrap.
Verification:
```bash
KUBECONFIG=worker01.kubeconfig kubectl auth can-i get secrets -n linkerd --as=system:serviceaccount:flux-system:source-controller
```

### 11. Deploy Worker Cluster Workloads via Infra Flux
Create remote `Kustomization` objects in the Infra cluster that point (`spec.path`) to worker workload directories and include `spec.kubeConfig.secretRef`.
Example (excerpt):
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: worker01-namespaces
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
  path: ./environments/production/workers/worker01/cluster/namespaces
  prune: true
  kubeConfig:
    secretRef:
      name: kubeconfig
```
Apply and verify:
```bash
kubectl apply -f environments/production/workers/worker01/cluster/apps/worker01-namespaces.yaml
flux get kustomizations -A | grep worker01-namespaces
KUBECONFIG=worker01.kubeconfig kubectl get ns
```

### 12. Validate Remote Secrets & Namespaces
Check that namespaces and Secrets targeted for the Worker cluster exist there:
```bash
kubectl --context <worker-context> get ns envoy-gateway-system linkerd
kubectl --context <worker-context> get secret -n envoy-gateway-system extauthz-signing-keys-secret
```

### 13. Encryption / Decryption Local Workflow
```bash
make decrypt-secrets   # TEMPORARY local edit (NEVER commit decrypted state)
# ... edit ...
make encrypt-secrets   # re-encrypt before staging
git add <files>
git commit -m "feat: add <secret>"
```
If commit blocked: run `grep -n '^stringData:' <file>` and ensure `sops:` block + `ENC[` lines exist.

### 14. AGE Key Rotation
```bash
age-keygen -o new.age.agekey
kubectl -n flux-system create secret generic sops-age-new --from-file=age.agekey=new.age.agekey
# Add new public key to .sops.yaml creation_rules
make encrypt-secrets
git commit -m "chore: add new age recipient & re-encrypt"
kubectl -n flux-system delete secret sops-age   # after verifying decryption with new key
kubectl -n flux-system rename secret sops-age-new sops-age || echo "Manual rename may be required"
```

### 15. Cross-Cluster Secret Sync (Infra -> Worker)
This section explains how encrypted Secrets in Git for the Infra cluster are decrypted by Flux and then applied to a remote Worker cluster using `spec.kubeConfig` on a Flux Kustomization, and (optionally) how External Secrets Operator (ESO) can consume secrets with least privilege RBAC.

### 15.0 ESO Release
Check the Helm Release of ESO have enable this in values:
```yaml
  values:
    # Create / use dedicated controller ServiceAccount
    serviceAccount:
      create: true
      name: external-secrets-controller
      annotations: {}
      automount: true
```

#### 15.1 Flow Overview
1. Secret manifest lives in Git under `apps/production/workers/worker01/.../secrets/` (or `environments/.../secrets/`).
2. Secret is SOPS-encrypted (age recipients) – only `stringData`/`data` keys encrypted.
3. Infra Flux `Kustomization` (running in Infra cluster) has:
   * `spec.decryption.secretRef.name: sops-age` → decrypts before apply.
   * `spec.kubeConfig.secretRef.name: kubeconfig` → uses remote kubeconfig credentials to apply the decrypted Secret to Worker API server.
4. Remote Worker cluster receives the Secret (namespace must pre-exist remotely).
5. ESO or workload in Worker cluster consumes the Secret.

#### 15.2 Minimal Remote Secret Kustomization (Example)
File: `environments/production/workers/worker01/cluster/apps/envoy-gateway-secrets.yaml`
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: envoy-gateway-secrets
  namespace: envoy-gateway-system
spec:
  interval: 10m
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  path: ./apps/production/workers/worker01/envoy-gateway/extauthz/secrets
  prune: true
  dependsOn:
    - name: namespaces
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  kubeConfig:
    secretRef:
      name: kubeconfig
```

Important: Avoid adding a global patch that overwrites `targetNamespace` incorrectly for this Kustomization or the secrets will land in Infra instead of Worker.

#### 15.3 Kubeconfig Secret
Create a Secret `kubeconfig` in Infra cluster (namespace where Flux looks) containing a kubeconfig with minimal RBAC:
```bash
kubectl -n flux-system create secret generic kubeconfig \
  --from-file=value.yaml=./worker01.kubeconfig
```
Ensure CA data and cluster server endpoint are present. Optionally restrict token user to read/write only required namespaces (NOT cluster-admin).

#### 15.4 Namespace Presence
Before remote apply, the namespace must exist on Worker cluster:
```bash
kubectl --context worker01 get ns envoy-gateway-system || \
kubectl --context worker01 create ns envoy-gateway-system
```
You can also manage remote namespaces via a separate remote Kustomization using the same kubeConfig.

#### 15.5 RBAC for Remote Sync & ESO
Apply RBAC in Worker cluster (`setup/rbac.yaml`) so Infra-issued OIDC user identities (`infra-cluster-oidc:system:serviceaccount:flux-system:<controller>`) have required rights. Least privilege Roles (e.g. `kms-system-remote-sync-secrets-read`) grant only secret read in specific namespaces. Provide fallback RoleBindings without prefix if the API server omits the configured prefix.

#### 15.6 External Secrets Operator (ESO) Notes
If using ESO to mirror or transform secrets:
* Confirm chart is installed (`HelmRelease external-secret`).
* ServiceAccount `external-secrets-controller` must have read on namespaces where upstream secrets land (see RBAC Role + RoleBinding).
* Avoid relying on projected tokens with custom audiences until confirmed supported; stick to standard audience provided in AuthenticationConfiguration.

#### 15.7 Troubleshooting Remote Secret Delivery
| Issue | Check | Fix |
|-------|-------|-----|
| Secret appears only in Infra cluster | Does Kustomization lack `spec.kubeConfig`? Was `targetNamespace` patched? | Add kubeConfig or remove unintended patch injecting local targetNamespace. |
| SOPS decryption fails remotely | Flux logs show MAC mismatch? | Re-run `make encrypt-secrets`; ensure `sops-age` Secret exists in Infra cluster. |
| Namespace not found errors | Namespace exists in Infra only | Create namespace in Worker or manage it via remote namespaces Kustomization. |
| ESO cannot read secret | RBAC RoleBinding lacks user subject | Apply `setup/rbac.yaml`; verify username prefix matches AuthenticationConfiguration. |
| Token audience mismatch | ServiceAccount token has wrong `aud` claim | Remove custom audience override; rely on default accepted audiences (`kubernetes`, `gardener`). |

#### 15.8 Verification Commands
```bash
# Infra side: ensure Kustomization ready
flux get kustomizations -A | grep envoy-gateway-secrets

# Worker side: verify secret landed
kubectl --context worker01 get secret -n envoy-gateway-system extauthz-signing-keys-secret -o yaml | grep -E 'data:'

# View controller logs for decryption errors
flux logs --kind Kustomization --follow | grep envoy-gateway-secrets
```

#### 15.9 Recommended Hardening
* Use a dedicated ServiceAccount/token in kubeconfig with restricted namespace permissions.
* Periodically rotate kubeconfig credentials; store encrypted at rest (Vault, SOPS with different rule set).
* Add Admission Policies to prevent plaintext Secrets creation on Infra cluster.
* Enable alerting on Flux Kustomization failures (Prometheus alerts / Alertmanager routes).

---
End of cross-cluster secret sync section.

### 16. External Secrets Cross-Cluster Linkerd CA Sync
This describes how the Infra cluster obtains (and optionally republishes) the Linkerd identity issuer (CA) Secret from a Worker cluster using External Secrets Operator (ESO) and a `ClusterSecretStore` with the Kubernetes provider.

#### 16.1 Goal
Consume the remote Worker cluster Secret `linkerd-identity-issuer` (namespace `linkerd`) and materialize it in the Infra cluster so components (e.g., multi-cluster mTLS validators or monitoring) can reference the issuer without storing it manually. The resulting local Secret is managed via an `ExternalSecret` and refreshes periodically.

#### 16.2 Components
* ServiceAccount `kms-system-remote-sync` (Infra cluster) – subject becomes OIDC user `infra-cluster-oidc:system:serviceaccount:flux-system:kms-system-remote-sync` in Worker cluster.
* RBAC in Worker cluster granting read-only access to `linkerd` namespace Secrets (Role + RoleBinding in `setup/rbac.yaml`).
* `ClusterSecretStore` (Infra) using the Kubernetes provider pointing to the Worker API server + CA bundle + serviceAccount token.
* `ExternalSecret` referencing the `ClusterSecretStore` and pulling the full Secret via `dataFrom.extract`.
* Flux HelmRelease `linkerd-identity-issuer-syncer` (generic chart) templates the `ExternalSecret` resource.

#### 16.3 ClusterSecretStore Example
Excerpt (from `apps/base/kms-system/release/release.yaml`):
```yaml
cluster-secret-store-vault-backend-common:
  apiVersion: external-secrets.io/v1
  kind: ClusterSecretStore
  metadata:
    name: vault-backend-worker01
  spec:
    provider:
      kubernetes:
        remoteNamespace: linkerd
        auth:
          serviceAccount:
            name: kms-system-remote-sync
            namespace: flux-system
        server:
          url: https://api.worker01.kms.shoot.gardener.cc-one.showroom.apeirora.eu
          caBundle: <BASE64_CA>
```
Notes:
* `remoteNamespace` allows referencing Secrets in that namespace without repeating the namespace.
* `serviceAccount` auth assumes ESO is querying a cluster reachable via the API server address. For true cross-cluster where the Infra ESO must talk to Worker API, ensure network reachability (VPN / VPC peering) and that the token audience matches API server expectations.
* `caBundle` must be the PEM (base64 inline) of the Worker cluster CA (matches kubeconfig CA).

#### 16.4 ExternalSecret Definition
Excerpt (from `apps/production/infra/linkerd/identity-issuer-syncer/release/release.yaml`):
```yaml
linkerd-identity-issuer-syncer-worker01:
  apiVersion: external-secrets.io/v1
  kind: ExternalSecret
  metadata:
    name: worker01-linkerd-ca
    namespace: worker01
  spec:
    dataFrom:
      - extract:
          key: linkerd-identity-issuer
    refreshInterval: 1m
    secretStoreRef:
      kind: ClusterSecretStore
      name: vault-backend-worker01
    target:
      creationPolicy: Owner
      deletionPolicy: Retain
      name: linkerd-identity-issuer
```
Key Points:
* `dataFrom.extract.key` pulls all key/value pairs from the remote Secret.
* Target name may differ from metadata.name; here it intentionally mirrors remote origin.
* `refreshInterval` controls polling frequency (balance between eventual consistency and API load).

#### 16.5 RBAC Requirements (Worker Cluster)
In `setup/rbac.yaml`, ensure Role grants `get,list,watch` on Secrets in `linkerd` and RoleBinding ties to the OIDC user subject of the Infra cluster ServiceAccount:
```yaml
kind: Role
metadata:
  name: kms-system-remote-sync-secrets-read
  namespace: linkerd
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get","list","watch"]
```
Fallback bindings without the prefix mitigate cases where API server does not apply the structuredAuthentication prefix.

#### 16.6 Token / Auth Considerations
* ServiceAccount token used by ESO must be issued for audience(s) accepted by Worker API.
* If structuredAuthentication is active, verify subject format matches RBAC: decode token (`jwt decode`) or inspect from a debug sidecar.
* Avoid relying on projected tokens with custom audiences until confirmed stable; keep defaults.

#### 16.7 Validation Steps
```bash
# Infra cluster – ExternalSecret status
kubectl get externalsecret -A | grep worker01-linkerd-ca
kubectl describe externalsecret -n worker01 worker01-linkerd-ca | grep -i status

# Resulting synced Secret exists in Infra cluster
kubectl get secret -n worker01 linkerd-identity-issuer -o yaml | head -n 20

# Worker cluster original Secret
kubectl --context worker01 get secret -n linkerd linkerd-identity-issuer -o yaml | head -n 20
```
Compare data keys; they should match. `creationPolicy: Owner` means deleting the ExternalSecret will remove the synced Secret (unless `Retain` chosen otherwise).
