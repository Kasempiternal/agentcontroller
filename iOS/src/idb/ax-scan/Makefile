XCODE_FRAMEWORKS = /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks
OUTPUT = ax-scan

INSTALL_DIR = $(HOME)/.agentcontroller/ios/bin

# FBControlCore/FBSimulatorControl ship with idb-companion. Search every known
# runtime root (ours first, then legacy install layouts kept for compatibility),
# and finally the Homebrew install itself.
FRAMEWORK_CANDIDATES = \
	$(HOME)/.agentcontroller/ios/idb-companion/Frameworks \
	$(HOME)/.blitz-iphone-mcp/idb-companion/Frameworks \
	$(HOME)/.blitz-ios-mcp/idb-companion/Frameworks \
	$(HOME)/.blitz/idb-companion/Frameworks \
	$(shell brew --prefix idb-companion 2>/dev/null)/Frameworks

EFFECTIVE_IDB_FRAMEWORKS = $(shell for d in $(FRAMEWORK_CANDIDATES); do if [ -d "$$d" ]; then echo "$$d"; break; fi; done)

.PHONY: all clean install

all: $(OUTPUT)

install: $(OUTPUT)
	mkdir -p $(INSTALL_DIR)
	cp $(OUTPUT) $(INSTALL_DIR)/$(OUTPUT)

$(OUTPUT): ax-scan.m
	@if [ -z "$(EFFECTIVE_IDB_FRAMEWORKS)" ]; then echo "error: idb-companion frameworks not found (brew install idb-companion)"; exit 1; fi
	clang -fobjc-arc -fmodules \
		-F$(EFFECTIVE_IDB_FRAMEWORKS) \
		-F$(XCODE_FRAMEWORKS) \
		-framework FBControlCore \
		-framework FBSimulatorControl \
		-framework Foundation \
		-rpath $(EFFECTIVE_IDB_FRAMEWORKS) \
		-o $(OUTPUT) ax-scan.m

clean:
	rm -f $(OUTPUT)
