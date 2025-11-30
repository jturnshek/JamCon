# JamCon Makefile
# Use 'make run' to build, sign, and run the app with a stable identifier
# This ensures Accessibility permissions persist across rebuilds

.PHONY: build sign run clean

# Stable identifier for code signing (keeps Accessibility permission across rebuilds)
IDENTIFIER = com.jamcon.app
BINARY = .build/debug/JamCon

build:
	swift build

sign: build
	@echo "Signing with identifier: $(IDENTIFIER)"
	codesign -s - --force --identifier "$(IDENTIFIER)" $(BINARY)

run: sign
	@echo "Starting JamCon..."
	$(BINARY)

clean:
	swift package clean
	rm -rf .build

# Build release version
release:
	swift build -c release
	codesign -s - --force --identifier "$(IDENTIFIER)" .build/release/JamCon

help:
	@echo "Available targets:"
	@echo "  make build   - Build the project"
	@echo "  make sign    - Build and sign with stable identifier"
	@echo "  make run     - Build, sign, and run the app"
	@echo "  make clean   - Remove build artifacts"
	@echo "  make release - Build release version"
