.PHONY: build clean

DYLIB_SRC = Plugin/WeChatTweakPlugin.m
DYLIB_OUT = WeChatTweakPlugin.dylib

build:: $(DYLIB_OUT)
	swift build -c release
	cp -f .build/release/wechattweak ./wechattweak

$(DYLIB_OUT): $(DYLIB_SRC)
	clang -dynamiclib \
		-arch arm64 \
		-mmacosx-version-min=12.0 \
		-framework Foundation \
		-fobjc-arc \
		-O2 \
		-o $(DYLIB_OUT) \
		$(DYLIB_SRC)
	codesign --force --sign - $(DYLIB_OUT)

clean::
	rm -rf .build
	rm -f wechattweak
	rm -f $(DYLIB_OUT)
