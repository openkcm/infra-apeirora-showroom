## ApeiroRA Showroom Infra & Worker Cluster Setup

### Table of Contents

**Basics**
- [Prerequisites](#prerequisites)

**Bootstrap Infra Cluster**
1. [Create the Infra Cluster](#1-create-the-infra-cluster-gardener-shoot)
2. [Install Flux on Infra Cluster](#2-install-flux-on-infra-cluster)
3. [Apply Infra Cluster Manifests](#3-apply-infra-cluster-manifests)
4. [Add SOPS Age Key Secret](#4-add-sops-age-key-secret)
5. [Encrypt Any New Secrets](#5-encrypt-any-new-secrets)
6. [Verify Test Secret Decryption](#6-verify-test-secret-decryption)
7. [Apply Structured Authentication ConfigMap](#7-apply-structured-authentication-configmap-issuer)

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
Create the Worker shoot similarly and ensure structured authentication is enabled. Example Gardener shoot snippet:
```yaml
kubernetes:
  kubeAPIServer:
    structuredAuthentication:
      configMapName: showroominfra-issuer-configmap
```

### 9. Provide Cluster CA of Worker to Infra
Copy CA from the kubeconfig to the kubeconfig in  environments/<stage>/workers/<name>/secrets/kubeconfig

### 10. Apply RBAC on Worker Cluster
Pre-create Roles and RoleBindings on the Worker cluster so the Infra Flux controllers (via OIDC subject prefix) and any dedicated remote sync ServiceAccounts have least privilege access.
```bash
kubectl apply -f setup/rbac.yaml
```
Key points:
* Role names ending in `-secrets-read` grant `get,list,watch` on Secrets only.
* Bindings include subjects with and without the username prefix (`infra-cluster-oidc:`) to handle API server differences.
* Avoid granting cluster-admin unless required for bootstrap.
Verification:
```bash
kubectl auth can-i get secrets -n linkerd --as=system:serviceaccount:flux-system:source-controller
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

### 15. SOPS Secrer Management
This section explains how encrypted Secrets in Git for the Infra cluster are decrypted by Flux and then applied to a remote Worker cluster using `spec.kubeConfig` on a Flux Kustomization, and (optionally) how External Secrets Operator (ESO) can consume secrets with least privilege RBAC.


#### 15.1 Flow Overview
1. Secret manifest lives in Git under `apps/production/workers/worker01/.../secrets/` (or `environments/.../secrets/`).
2. Secret is SOPS-encrypted (age recipients) – only `stringData`/`data` keys encrypted.
3. Infra Flux `Kustomization` (running in Infra cluster) has:
   * `spec.decryption.secretRef.name: sops-age` → decrypts before apply.
   * `spec.kubeConfig.secretRef.name: kubeconfig` → uses JWT of flux Service ACCOUNT for authentication.
   * kubeconfig is only need for remote cluster.
4. Remote Worker cluster receives the Secret
5. Workload in Worker cluster consumes the Secret.

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

#### 15.3 Kubeconfig Secret
Kubceconfig is managed in environments/production/workers/name/secret/kubeconfig

#### 15.4 RBAC for Remote Sync & ESO
Apply RBAC in Worker cluster (`setup/rbac.yaml`) so Infra-issued OIDC user identities (`infra-cluster-oidc:system:serviceaccount:flux-system:<controller>`) have required rights. Least privilege Roles (e.g. `kms-system-remote-sync-secrets-read`) grant only secret read in specific namespaces. Provide fallback RoleBindings without prefix if the API server omits the configured prefix.

#### 15.5 External Secrets Operator (ESO) Notes
If using ESO to mirror or transform secrets:
* Confirm chart is installed (`HelmRelease external-secret`).
* ServiceAccount `external-secrets-controller` must have read on namespaces where upstream secrets land (see RBAC Role + RoleBinding).
* Avoid relying on projected tokens with custom audiences until confirmed supported; stick to standard audience provided in AuthenticationConfiguration.

#### 15.6 Verification Commands
```bash
# Infra side: ensure Kustomization ready
flux get kustomizations -A | grep envoy-gateway-secrets

# Worker side: verify secret landed
kubectl --context worker01 get secret -n envoy-gateway-system extauthz-signing-keys-secret -o yaml | grep -E 'data:'

# View controller logs for decryption errors
flux logs --kind Kustomization --follow | grep envoy-gateway-secrets
```
---
End of cross-cluster secret sync section.

### 16. External Secrets Cross-Cluster Linkerd CA Sync
This describes how the Infra cluster obtains (and optionally republishes) the Linkerd identity issuer (CA) Secret from a Worker cluster using External Secrets Operator (ESO) and a `ClusterSecretStore` with the Kubernetes provider.

#### 16.1 Goal
Consume the remote Worker cluster Secret `linkerd-identity-issuer` (namespace `linkerd`) and materialize it in the Infra cluster so flux helm release can access it to install linkerd on remote cluster.

#### 16.2 Components
* ServiceAccount `external-secrets-controller` (Infra cluster) – subject becomes OIDC user `infra-cluster-oidc:system:serviceaccount:flux-system:external-secrets-controller` in Worker cluster.
* RBAC in Worker cluster granting read-only access to `linkerd` namespace Secrets (Role + RoleBinding in `setup/rbac.yaml`).
* `ClusterSecretStore` (Infra) using the Kubernetes provider pointing to the Worker API server + CA bundle + serviceAccount token (Read from POD).
* `ExternalSecret` referencing the `ClusterSecretStore` and pulling the full Secret via `dataFrom.extract`.
* Flux HelmRelease `linkerd-identity-issuer-syncer` (generic chart) templates the `ExternalSecret` resource.

#### 16.2.1 ESO Helm Release

This need to be in the values:
```yaml
serviceAccount:
  create: true
  name: external-secrets-controller
  annotations: {}
  automount: true
```

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
* `serviceAccount` auth assumes ESO is querying a cluster reachable via the API server address. For true cross-cluster where the Infra ESO must talk to Worker API.
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

#### 16.5 RBAC Requirements (Worker Cluster)
In `setup/rbac.yaml`, ensure Role grants `get,list,watch` on Secrets in `linkerd` and RoleBinding ties to the OIDC user subject of the Infra cluster ServiceAccount.
Namespace 'linkerd' need pre crated to apply this.

#### 16.6 Token / Auth Considerations
* ServiceAccount token used by ESO must be issued for audience(s) accepted by Worker API.
* If structuredAuthentication is active, verify subject format matches RBAC: decode token (`jwt decode`) or inspect from a debug sidecar.

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

### 17. OpenBao Setup Guide

This document describes how OpenBao is deployed, secured, and automated in this repository.

## Goals

* Use PostgreSQL as the storage backend.
* Using External Secret to template Database Connection.
* Enforce TLS and later mTLS for all client connections.
* Automate certificate → policy mapping using annotations.
* Provide least-privilege policies (admin, app1, key-admin, namespace-admin).
* Enable JWT authentication (Local Cluster issuer discovery) alongside certificate auth. For UI AUTH.
* UI Only accesable with port forwarding.
* Automate unseal via sidecar container.
* Keep secrets encrypted at rest in Git with SOPS/AGE.

## Components Overview

| Component | Location | Purpose |
|-----------|----------|---------|
| Pre-release HelmRelease | `apps/base/openbao/pre-release/release.yaml` | Bootstraps storage secret, CA issuers/certs, client certs, policy Secrets, and CronJob automation. |
| Main HelmRelease | `apps/base/openbao/release/release.yaml` | Deploys OpenBao server chart with TLS, storage config, and unseal sidecar. |
| ExternalSecret (Postgres) | Pre-release values | Generates `openbao-postgres-storage` secret with `config.hcl`. |
| cert-manager Issuers & Certificates | Pre-release values | Establish server CA, client CA, injector CA, and client certificates. |
| Policy Secrets | Pre-release values | Store HCL policy definitions used by sync CronJob. |
| CronJob `openbao-cert-auth-sync` | Pre-release values | Upserts policies, enables auth methods, maps annotated cert Secrets to cert auth roles. |
| Unseal Sidecar | Main HelmRelease values (`extraContainers`) | Submits unseal keys automatically after pod start. |
| Root Token Secret | (External to chart) | Provides with sops |

## Storage Backend (PostgreSQL)

Defined in the ExternalSecret template:
```
storage "postgresql" {
  connection_url = "postgres://openbao:${openbao}@openbao-postgresql.openbao.svc.cluster.local:5432/openbao?sslmode=require"
}
```
The password is sourced from the Zalando Postgres operator secret, exposed into `openbao-postgres-storage` and mounted by the main release via `userconfig-openbao-storage-config`.

## TLS & mTLS

1. Self-signed issuer `openbao-selfsigned` creates the server CA (`openbao-server-ca`).
2. Server certificate `openbao-tls` signed by server CA.
3. Client CA bootstrap and rotation policy create a persistent client CA (`openbao-client-ca`) and issuer.
4. Client certificates (admin, key-admin, namespace-admin, app1) request `client auth` usage and are annotated with `openbao.cert.auth/policy`.
5. Main HelmRelease mounts server cert, client CA, and admin client cert.

## Policy Management

Policies live as Secrets with names prefixed by `openbao-policy-`. Each Secret may contain multiple `*.hcl` keys; the CronJob iterates, extracts content, and PUTs to `/v1/sys/policies/acl/<name>`.

Policies implemented:

* `admin-policy.hcl`: Explicit paths for token ops, mounts, transit, policy management, JWT auth, and read/list fallback.
* `app1-policy.hcl`: Read/list on `kv/data/app1/*`.
* `key-admin-policy.hcl`: Manage KV + transit keys & encrypt/decrypt operations.
* `namespace-admin-policy.hcl`: Namespace management (ignored by OSS OpenBao but retained for possible Enterprise usage).

## Certificate → Policy Mapping

The CronJob scans Secrets with annotation `openbao.cert.auth/policy`. For each secret with a `tls.crt`, it posts a role to `/v1/auth/cert/certs/<secret>` binding the certificate's Common Name(s) to the specified policy list.

Annotation format supports multiple comma-separated policies (e.g. `admin-policy,key-admin-policy`).

## Authentication Methods

### Certificate Auth
Enabled automatically when missing:
```
POST /v1/sys/auth/cert {"type":"cert"}
```
Roles created per annotated Secret.

### JWT Auth
CronJob:
* Enables `/jwt` auth method if absent.
* Configures discovery with `oidc_discovery_url` == external issuer.
* Creates `jwt-admin` role (`role_type=jwt`) bound to audiences `["vault","openbao","api"]` and attaches `admin-policy`.

Future hardening: introduce additional JWT roles mapping to app policies.

## Transit Engine

Mounted if `/transit/` is absent:
```
POST /v1/sys/mounts/transit {"type":"transit"}
```
`key-admin` policy allows key management and encryption/decryption; you must set `deletion_allowed=true` per key when generating if you intend to remove keys later.

## Unseal Automation

The unseal sidecar:
* Waits for HTTPS health endpoint with mTLS using admin client cert.
* Iterates through mounted unseal key files in `openbao-unseal-keys` Secret.
* POSTs each key to `/v1/sys/unseal` until unsealed.
* Only works after Initials Setup in a new Cluster is done.

## CronJob Workflow Details

Sequence (every 10 minutes):
1. Waits for unseal status.
2. Enables cert & jwt auth methods if missing.
3. Configures JWT issuer & ensures role `jwt-admin` with proper `role_type`.
4. Upserts all policy Secrets.
5. Mounts transit engine if needed.
6. Processes annotated certificate Secrets and creates/updates cert auth roles.

Resilience: Each step checks presence before creation to avoid overwriting.

## How to Add a New Client Policy & Certificate

1. Add a new policy Secret (e.g. `openbao-policy-myapp`) with `myapp-policy.hcl`.
2. Create a `Certificate` specifying `secretTemplate.annotations.openbao.cert.auth/policy: myapp-policy`.
3. Commit and let Flux reconcile.
4. CronJob run will publish the policy and certificate auth role automatically.

## References

* OpenBao Docs: https://www.openbao.org/
* cert-manager: https://cert-manager.io/docs/
* External Secrets Operator: https://external-secrets.io/latest/
