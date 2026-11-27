PYTHON ?= python3
JOBS ?= 8
export PYTHON JOBS

graphics_components := graphics-angle graphics-swiftshader-gles graphics-swiftshader-vulkan graphics-vulkan graphics-mesa

.PHONY: check build qt netsim graphics $(graphics_components) firmware package verify

check:
	shellcheck ci/*.sh scripts/*.sh tests/init
	$(PYTHON) -m ruff format --check scripts
	$(PYTHON) -m ruff check scripts
	$(PYTHON) -m mypy --strict --scripts-are-modules scripts

build: qt netsim graphics firmware
	$(MAKE) package

graphics: $(graphics_components)

qt netsim $(graphics_components) firmware package:
	bash scripts/component.sh $@

verify:
	$(PYTHON) scripts/verify.py
