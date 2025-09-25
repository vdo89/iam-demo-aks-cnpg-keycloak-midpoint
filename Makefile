.PHONY: fmt test bootstrap

fmt:
terraform -chdir=infra/azure/terraform fmt

bootstrap:
scripts/bootstrap.sh

TEST_ARGS?=

test:
python -m pytest $(TEST_ARGS)
