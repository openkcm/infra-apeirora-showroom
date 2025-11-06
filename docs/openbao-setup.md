# OpenBao Setup & PKI Integration

## Overview
This document describes how OpenBao (Vault-compatible) is deployed, configured, and integrated with cert-manager to issue client certificates via the OpenBao PKI secrets engine.

## Components
- Storage: PostgreSQL (configured via ExternalSecret generating `config.hcl`)
- TLS: cert-manager issued server certificate (`openbao-tls`)
- Client Auth: cert-manager issued client certificates annotated with `openbao.cert.auth/policy`
- Auth Methods: cert, jwt, kubernetes (for cert-manager)
- Secrets Engines: transit, pki (root), pki_int (intermediate)
- Automation: CronJob `openbao-cert-auth-sync` performing idempotent convergence

## PKI Architecture
Two PKI mounts are used:
- `pki/` (root CA) with very long TTL; holds the root certificate
- `pki_int/` (intermediate) used for issuing end-entity client certificates through role `client-cert`

cert-manager integrates using a `ClusterIssuer` referencing Vault's PKI issue path `pki_int/issue/client-cert` via kubernetes auth role `cert-manager-pki`.

## Added Policy: `openbao-pki-client`
Allows:
- Issue certificates: `pki_int/issue/client-cert`
- Read root/intermediate CA chains and CRL for trust distribution

## Automation Flow (CronJob)
Each run ensures:
1. Unsealed status
2. Auth methods enabled: cert, jwt, kubernetes
3. JWT configured & role `jwt-admin` present
4. Policies synced from Kubernetes Secrets (`openbao-policy-*`)
5. Transit engine mounted
6. Kubernetes auth configured (token reviewer, host, CA) & role `cert-manager-pki` present
7. PKI mounts (`pki`, `pki_int`) created if missing
8. Root CA generated if absent; URLs configured
9. Intermediate CSR generated, signed by root, imported
10. PKI role `client-cert` created (RSA 2048, TTL 24h, max 30d)
11. Annotated client cert Secrets mapped into cert auth backend

All steps are idempotent; failures are logged but do not abort earlier successful configuration.

## ClusterIssuer
`apps/base/openbao/pre-release/pki-clusterissuer.yaml` creates:
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: openbao-pki
spec:
  vault:
    server: https://openbao.openbao.svc:8200
    path: pki_int/issue/client-cert
    auth:
      kubernetes:
        mountPath: /v1/auth/kubernetes
        role: cert-manager-pki
```
The `issuerRef` points to root CA secret if needed for trust. (Optional `caBundle` can be supplied.)

## Requesting a Certificate
Example `Certificate` resource using the ClusterIssuer:
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: demo-client
  namespace: openbao
spec:
  secretName: demo-client-cert
  commonName: demo-client
  usages:
    - digital signature
    - key encipherment
    - client auth
  issuerRef:
    name: openbao-pki
    kind: ClusterIssuer
  duration: 24h
  renewBefore: 2h
```

## Verifying Issuance
1. Apply the Certificate manifest.
2. Check status:
```sh
kubectl describe certificate demo-client -n openbao | grep -i condition
kubectl get secret demo-client-cert -n openbao
```
3. Confirm CSR triggered Vault issuance (intermediate chain inside secret).
4. Optionally inspect Vault lease:
```sh
curl -s --cacert <CA_CERT> --cert <ADMIN_CERT> --key <ADMIN_KEY> -H "X-Vault-Token: $(cat /root-token/root-token)" \
  https://openbao.openbao.svc:8200/v1/pki_int/certs | jq '.data.keys | length'
```

## Revocation & CRL
To revoke:
```sh
SERIAL=$(openssl x509 -in <(kubectl get secret demo-client-cert -n openbao -o jsonpath='{.data.tls\.crt}' | base64 -d) -noout -serial | cut -d'=')
curl -s --cacert <CA_CERT> --cert <ADMIN_CERT> --key <ADMIN_KEY> -H "X-Vault-Token: $(cat /root-token/root-token)" \
  -X POST https://openbao.openbao.svc:8200/v1/pki_int/revoke -d '{"serial_number":"'$SERIAL'"}'
```
CRL endpoint: `https://openbao.openbao.svc:8200/v1/pki_int/crl`.

## Security & Hardening Notes
- Replace root token usage in CronJob with limited policy token (future task)
- Consider restricting `allow_any_name` in PKI role and enforce organization/unit constraints
- Regularly rotate intermediate (set shorter TTL; re-sign through root)
- Monitor issuance counts and CRL size

## Troubleshooting
| Symptom | Check | Fix |
|---------|-------|-----|
| ClusterIssuer Pending | `kubectl describe clusterissuer openbao-pki` | Ensure kubernetes auth role & policy exist; CronJob logs |
| Certificate Secret empty | Describe Certificate events | PKI role missing or Vault unreachable |
| CRL fetch fails | Curl PKI endpoints | Verify PKI mounts & URL config |
| Issuance uses root directly | Path misconfigured (`pki/issue/...`) | Use `pki_int/issue/client-cert` |

## Next Steps
- Migrate admin operations off root token
- Add audit device
- Limit SANs / enforce OUs in role
- Integrate with service mesh identities
