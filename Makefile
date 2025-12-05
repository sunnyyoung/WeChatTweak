.PHONY: build clean

build::
	swift build -c release --arch arm64 --arch x86_64
	cp -f .build/apple/Products/Release/wechattweak ./wechattweak

clean::
	rm -rf .build
	rm -f wechattweak
