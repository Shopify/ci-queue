# Copyright (c) 2017 "Shopify inc." All rights reserved.
# Use of this source code is governed by a MIT-style license that can be found in the LICENSE file.
python_files := find . -path '*/.*' -prune -o -name '*.py' -print0
python_version_full := $(wordlist 2,4,$(subst ., ,$(shell python --version 2>&1)))
python_version_major := $(word 1,${python_version_full})

all: test

clean:
	find . \( -name '*.pyc' -o -name '*.pyo' -o -name '*~' \) -print -delete >/dev/null
	find . -name '__pycache__' -exec rm -rvf '{}' + >/dev/null

autopep8:
	@echo 'Auto Formatting...'
	@$(python_files) | xargs -0 autopep8 --jobs 0 --in-place --aggressive --global-config setup.cfg

lint:
	@echo 'Linting...'
	@pylint --rcfile=pylintrc setup.py shopify_python tests.shopify_python
	@if [ "$(python_version_major)" = "3" ]; then \
		echo 'Checking type annotations...'; \
		mypy --py2 shopify_python tests/shopify_python --ignore-missing-imports; \
	fi
	@pycodestyle

autolint: autopep8 lint

run_tests: clean
	py.test --durations=10 tests

test: autopep8 run_tests lint

install:
	pip install -e .[dev]

release:
	rm -rf build dist
	@python setup.py sdist bdist_wheel

upload_test: release
	@twine upload dist/* -r testpypi

upload_pypi: release
	@twine upload dist/* -r pypi
