PYTHON ?= python3
JOBS ?= 8
export PYTHON JOBS

.PHONY: check build qt netsim graphics firmware package verify

check:
	shellcheck ci/*.sh scripts/*.sh tests/init
	$(PYTHON) -m ruff format --check scripts
	$(PYTHON) -m ruff check scripts
	$(PYTHON) -m mypy --strict --scripts-are-modules scripts

build: qt netsim graphics firmware
	$(MAKE) package

qt netsim graphics firmware package:
	bash scripts/component.sh $@

verify:
	$(PYTHON) scripts/verify.py
