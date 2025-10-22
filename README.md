# Infra ApeiroRA Showroom

Default templates for SAP open source repositories, including LICENSE, .reuse/dep5, Code of Conduct, etc... All repositories on github.com/SAP will be created based on this template.

[![REUSE status](https://api.reuse.software/badge/github.com/openkcm/infra-apeirora-showroom)](https://api.reuse.software/info/github.com/openkcm/infra-apeirora-showroom)

## About this project

This repository is used for managing infrastructure and application deployments on the ApeiroRA Showroom using Flux.


## Support, Feedback, Contributing

This project is open to feature requests/suggestions, bug reports etc. via [GitHub issues](https://github.com/openkcm/infra-apeirora-showroom/issues). Contribution and feedback are encouraged and always welcome. For more information about how to contribute, the project structure, as well as additional contribution information, see our [Contribution Guidelines](CONTRIBUTING.md).

## Security / Disclosure
If you find any bug that may be a security problem, please follow our instructions at [in our security policy](https://github.com/openkcm/infra-apeirora-showroom/security/policy) on how to report it. Please do not create GitHub issues for security-related doubts or problems.

## Code of Conduct

We as members, contributors, and leaders pledge to make participation in our community a harassment-free experience for everyone. By participating in this project, you agree to abide by its [Code of Conduct](https://github.com/openkcm/.github/blob/main/CODE_OF_CONDUCT.md) at all times.

## Licensing

Copyright (20xx-)20xx SAP SE or an SAP affiliate company and OpenKCM contributors. Please see our [LICENSE](LICENSE) for copyright and license information. Detailed information including third-party components and their licensing/copyright information is available [via the REUSE tool](https://api.reuse.software/info/github.com/openkcm/infra-apeirora-showroom).

## SOPS & Secrets Workflow

Encrypt Kubernetes Secret manifests placed under any `secrets/` directory. The `.sops.yaml` targets only `data` and `stringData` keys and skips `kustomization.yaml`.

Commands:

```bash
make encrypt-secrets   # encrypt all secrets/**/*
make decrypt-secrets   # decrypt locally (NEVER commit decrypted files)
```

For full Infra & Worker cluster bootstrap (Flux install, structuredAuthentication, RBAC, remote sync), see the setup guide: [setup/readme.md](./setup/readme.md).

### Git Hook Protection

Enable the provided pre-commit hook to block mistakes:

```bash
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit           # ensure executable so Git runs it
git add .githooks/pre-commit            # stage permission bit for others
git commit -m "chore: make pre-commit hook executable" || true
```

Verify it runs (should show hook output or succeed silently on empty commit):

```bash
git commit --allow-empty -m "hook test"
```

Troubleshooting:

* If you see: `hook was ignored because it's not set as executable` run:
	```bash
	chmod +x .githooks/pre-commit
	```
* To bypass in an emergency (NOT recommended for secrets work): `git commit -n -m "msg"`
* Update after pulling new hooks:
	```bash
	chmod +x .githooks/* || true
	```
* Disable (if ever needed):
	```bash
	git config --unset core.hooksPath
	```
```

The hook will fail the commit if:
* A file in a `secrets/` path still contains `stringData:` (not encrypted yet).
* A `kustomization.yaml` inside a secrets folder contains a `sops:` block.

Rotate AGE key:

```bash
age-keygen -o new.age.agekey
kubectl -n flux-system create secret generic sops-age-new --from-file=age.agekey=new.age.agekey
# Add new public key to .sops.yaml, re-encrypt, commit, remove old key.
```
