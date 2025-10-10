Secrets for production infra layer.

Usage:
- Place only Kubernetes Secret manifests here.
- Use stringData whenever possible for readability before encryption.
- Encrypt: `make encrypt-production-secrets`
- Decrypt (local only, never commit): `make decrypt-production-secrets`
