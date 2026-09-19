#!/bin/zsh
emulate -R zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
source scripts/swift-env.sh
app_dir="$project_dir/build/apple-speech-device/Apple Speech Check.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
# Generate fixed local fixtures without playing them or collecting microphone audio.
/usr/bin/say -v Tingting --file-format=WAVE --data-format=LEI16@16000 -o "$app_dir/Contents/Resources/zh-CN.wav" '今天的天气很好，我想用中文记录一条消息。'
/usr/bin/say -v Samantha --file-format=WAVE --data-format=LEI16@16000 -o "$app_dir/Contents/Resources/en-US.wav" 'The weather is nice today. Please write this message in English.'
for phrase in 第一 第二 第三; do
    /usr/bin/say -v Tingting --file-format=WAVE --data-format=LEI16@16000 \
        -o "$app_dir/Contents/Resources/$phrase.wav" "这是我的${phrase}句话"
done
python3 - "$app_dir/Contents/Resources" <<'PY'
import sys, wave
from pathlib import Path
for path in Path(sys.argv[1]).glob('*.wav'):
    with wave.open(str(path)) as audio:
        if audio.getnframes() == 0:
            raise SystemExit(f'No generated audio in {path.name}; run outside the sandbox with installed system voices.')
root = Path(sys.argv[1])
with wave.open(str(root / 'paused.wav'), 'wb') as paused:
    paused.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
    for phrase in ['第一', '第二', '第三']:
        with wave.open(str(root / f'{phrase}.wav')) as source:
            paused.writeframes(source.readframes(source.getnframes()))
        paused.writeframes(bytes(16000 * 2 * 4))
with wave.open(str(root / 'mixed.wav'), 'wb') as mixed:
    mixed.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
    for language in ['zh-CN', 'en-US', 'zh-CN']:
        with wave.open(str(root / f'{language}.wav')) as source:
            mixed.writeframes(source.readframes(source.getnframes()))
PY
cargo build --locked --release --target aarch64-apple-darwin
typeset -a sources=()
for source_file in macos/*.swift; do
    if [[ "$source_file" != macos/main.swift ]]; then sources+=("$source_file"); fi
done
swiftc -swift-version 6 -warnings-as-errors -O -target arm64-apple-macosx27.0 \
    -I runtime/include -I agent-bridge/include "${sources[@]}" tests/AppleSpeechDeviceTests.swift \
    target/aarch64-apple-darwin/release/libecho_runtime.a target/aarch64-apple-darwin/release/libecho_agent.a \
    -framework AppKit -framework SwiftUI -framework Security -framework AVFoundation -framework Speech -lz \
    -o "$app_dir/Contents/MacOS/AppleSpeechCheck"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AppleSpeechCheck</string>
<key>CFBundleIdentifier</key><string>local.chiyan.apple-speech-check</string>
<key>CFBundleName</key><string>Apple Speech Check</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSSpeechRecognitionUsageDescription</key><string>使用本机生成的固定中英文音频验证 Apple 本地识别，不录制麦克风，不使用云端识别。</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - --timestamp=none "$app_dir"
"$app_dir/Contents/MacOS/AppleSpeechCheck" "$@"
