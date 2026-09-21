#!/bin/zsh
emulate -R zsh
# Generate the device probe's audio resources before Xcode seals the bundle.
setopt ERR_EXIT NO_UNSET PIPE_FAIL
resources_dir="${TARGET_BUILD_DIR:?Run from an Xcode build phase}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?Missing resource path}"
mkdir -p "$resources_dir"
# Generate fixed local fixtures without playing them or collecting microphone audio.
/usr/bin/say -v Tingting --file-format=WAVE --data-format=LEI16@16000 -o "$resources_dir/zh-CN.wav" '今天的天气很好，我想用中文记录一条消息。'
/usr/bin/say -v Samantha --file-format=WAVE --data-format=LEI16@16000 -o "$resources_dir/en-US.wav" 'The weather is nice today. Please write this message in English.'
for phrase in 第一 第二 第三; do
    /usr/bin/say -v Tingting --file-format=WAVE --data-format=LEI16@16000 \
        -o "$resources_dir/$phrase.wav" "这是我的${phrase}句话"
done
python3 - "$resources_dir" <<'PY'
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
