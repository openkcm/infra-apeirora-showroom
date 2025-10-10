App-level secrets (production / infra / services).

Rules:
- Only Kubernetes Secret manifests.
- Use stringData before encryption.
- Encrypt with `make encrypt-production-secrets`.
