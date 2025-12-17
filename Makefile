PLATFORM_IOS = iOS Simulator,name=iPhone 15 Pro
PLATFORM_MACOS = macOS
PLATFORM_TVOS = tvOS Simulator,name=Apple TV
PLATFORM_WATCHOS = watchOS Simulator,name=Apple Watch Series 9 (45mm)

default: test

test:
	swift test

test-ios:
	xcodebuild test \
		-scheme SharingInstant \
		-destination platform="$(PLATFORM_IOS)"

test-macos:
	xcodebuild test \
		-scheme SharingInstant \
		-destination platform="$(PLATFORM_MACOS)"

build-all-platforms:
	for platform in "$(PLATFORM_IOS)" "$(PLATFORM_MACOS)" "$(PLATFORM_TVOS)" "$(PLATFORM_WATCHOS)"; do \
		xcodebuild build \
			-scheme SharingInstant \
			-destination platform="$$platform" || exit 1; \
	done

format:
	swift format \
		--ignore-unparsable-files \
		--in-place \
		--recursive \
		./Sources ./Tests

lint:
	swift format lint \
		--ignore-unparsable-files \
		--recursive \
		./Sources ./Tests

clean:
	swift package clean
	rm -rf .build

.PHONY: default test test-ios test-macos build-all-platforms format lint clean

