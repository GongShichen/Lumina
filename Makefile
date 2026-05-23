SWIFT ?= swift
XCODEBUILD ?= xcodebuild

.PHONY: test build clean xcode-test

build:
	$(SWIFT) build

test:
	$(SWIFT) test

xcode-test:
	$(XCODEBUILD) -scheme LocalAgentRuntime-Package -destination 'platform=macOS' test

clean:
	rm -rf .build .swiftpm

