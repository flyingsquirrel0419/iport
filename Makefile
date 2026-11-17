# iPort — make help
.PHONY: help bootstrap test project ipa runtime runtime-from-source clean

help:
	@echo "make bootstrap            fetch vendor/playport (Steam client, runtime sources)"
	@echo "make test                 IPortCore unit tests (Linux or macOS)"
	@echo "make ipa                  dist/iPort.ipa without the Windows runtime (macOS + Xcode)"
	@echo "make runtime              download the prebuilt Windows runtime into Runtime/ (runtime.lock)"
	@echo "make ipa RUNTIME=1        dist/iPort.ipa with the Windows runtime"
	@echo "make runtime-from-source  build the runtime yourself (x86-64 Linux, hours; see README)"
	@echo "No Mac? Fork on GitHub, Actions > Build IPA > Run workflow, download the artifact."

bootstrap:
	git submodule update --init vendor/playport

test:
	cd Packages/IPortCore && swift test

project: bootstrap
	python3 scripts/gen-project.py $(if $(filter 1,$(RUNTIME)),--runtime,)
	xcodegen generate --spec project.gen.yml --project .

ipa: bootstrap
	RUNTIME=$(RUNTIME) scripts/build-ipa.sh

runtime:
	scripts/fetch-runtime.sh

runtime-from-source:
	scripts/build-runtime.sh

clean:
	rm -rf build dist iPort.xcodeproj project.gen.yml Packages/IPortCore/.build
