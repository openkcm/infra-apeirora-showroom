.PHONY: reuse-lint encrypt-secrets decrypt-secrets help
reuse-lint:
	docker run --rm --volume $(PWD):/data fsfe/reuse lint

encrypt-secrets:
	@echo "Encrypting all secrets under environments/ and apps/ ..."
	@for dir in environments apps; do \
	  [ -d $$dir ] || continue; \
	  find $$dir -type f -path '*/secrets/*' \( -name '*.yaml' -o -name '*.yml' \) -exec sops -e -i {} \; ; \
	done

decrypt-secrets:
	@echo "Decrypting all secrets under environments/ and apps/ (DO NOT COMMIT decrypted files)..." ; \
	for dir in environments apps; do \
	  [ -d $$dir ] || continue; \
	  find $$dir -type f -path '*/secrets/*' \( -name '*.yaml' -o -name '*.yml' \) -exec sops -d -i {} \; ; \
	done

help:
	@echo "Targets: reuse-lint encrypt-secrets decrypt-secrets"
