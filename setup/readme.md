## ApeiroRA Showroom Infra & Worker Cluster Setup

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

Choose Mashine Type:

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
kubectl apply -f ./setup/issuer-config-map.yaml
```
If it is a new Cluster you need copy the new Issuer URL after cluster is created.
Contents define `AuthenticationConfiguration` with issuer audiences `kubernetes` & `gardener`, username prefix `infra-cluster-oidc:`.

### 8. Create Worker Cluster (Shoot) With Structured Auth Enabled
In the Worker cluster Shoot spec, set:
```yaml
kubernetes:
  kubeAPIServer:
    structuredAuthentication:
      configMapName: showroominfra-issuer-configmap
```
Ensure the ConfigMap is visible from the Worker cluster (Gardener projects namespace reference). If using a different project, replicate the ConfigMap there.
If you add this config to a existing cluster you need start manual a reconcile.

### 9. Provide Cluster CA of Worker to Infra (If Remote Sync Needed)
For remote secret sync or cross-cluster kubeconfigs, ensure the worker cluster CA is available where needed (e.g. embed it in the kubeconfig Secret or Gardener distributes automatically). Update any `kubeConfig` secrets used by Flux Kustomizations.

### 10. Apply RBAC on Worker Cluster
Switch kube-context to Worker cluster:
```bash
kubectl apply -f ./setup/rbac.yaml
```
RBAC grants:
* Cluster admin to Flux controllers via OIDC user subjects with prefix `infra-cluster-oidc:`.
* Least-privilege read Roles for remote sync ServiceAccounts (`kms-system-remote-sync`, `external-secrets-controller`) including fallback bindings without prefix in case API server omits it.

### 11. Deploy Worker Cluster Workloads via Infra Flux
Back on Infra kube-context, ensure Kustomizations using `spec.kubeConfig` for Worker cluster are applied (see `environments/production/workers/worker01/cluster/`). Monitor:
```bash
flux get kustomizations -A
flux logs --follow --kind Kustomization
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
