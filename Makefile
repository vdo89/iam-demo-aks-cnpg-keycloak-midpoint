.PHONY: test lint fmt

TEST?=pytest

## Run the Python test suite that validates GitOps manifests.
test:
$(TEST)
