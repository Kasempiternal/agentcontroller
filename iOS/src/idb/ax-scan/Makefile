IDB_FRAMEWORKS = $(HOME)/.blitz-ios-mcp/idb-companion/Frameworks
IDB_FRAMEWORKS_FALLBACK = $(HOME)/.blitz/idb-companion/Frameworks
XCODE_FRAMEWORKS = /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks
OUTPUT = ax-scan

INSTALL_DIR = $(HOME)/.blitz-ios-mcp/bin

# Use blitz-ios-mcp frameworks if available, otherwise fall back to blitz
EFFECTIVE_IDB_FRAMEWORKS = $(shell if [ -d "$(IDB_FRAMEWORKS)" ]; then echo "$(IDB_FRAMEWORKS)"; else echo "$(IDB_FRAMEWORKS_FALLBACK)"; fi)

.PHONY: all clean install

all: $(OUTPUT)

install: $(OUTPUT)
	mkdir -p $(INSTALL_DIR)
	cp $(OUTPUT) $(INSTALL_DIR)/$(OUTPUT)

$(OUTPUT): ax-scan.m
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
