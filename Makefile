MODULES := modules/aks
ROOTS   := envs/dev
TF      ?= terraform

.PHONY: all fmt validate lint security test
all: fmt validate lint security test

fmt:
	$(TF) fmt -recursive -check -diff

validate:
	@for d in $(MODULES) $(ROOTS); do \
	  echo "==> $$d"; (cd $$d && $(TF) init -backend=false -input=false >/dev/null && $(TF) validate) || exit 1; \
	done

lint:
	tflint --init && tflint --recursive

security:
	checkov -d . --framework terraform --quiet --compact

test:
	@for d in $(MODULES); do echo "==> $$d"; (cd $$d && $(TF) init -backend=false -input=false >/dev/null && $(TF) test) || exit 1; done
