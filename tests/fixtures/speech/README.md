# 固定 Speech 设备输入

保存自迁移前已经生成的 WAV，仅为合成语音，没有用户录音。所有资源是 16 kHz、单声道、PCM16。`paused.wav` 由“这是我的第一句话／第二句话／第三句话”分别追加四秒静音拼接；`mixed.wav` 是中文、英文、中文串联。生成来源为历史 `xcode-generate-speech-fixtures.sh` 的 Tingting/Samantha 短语。构建只复制资源。

| 文件 | 帧数 | SHA-256 |
|---|---:|---|
| `zh-CN.wav` | 73272 | `320fb5be56d8b7fce320c19c2b91d565c6274890c53eab9fa0c25bbd94e674a4` |
| `en-US.wav` | 57593 | `2330ef2e8b4959461195e49ff574ec207f376523c804694a1cddb1a9eb3cbbae` |
| `mixed.wav` | 204137 | `440454ec31de605b4b7ede5e7d4d2c4c30245090311958e94794ec75589e1e15` |
| `paused.wav` | 278313 | `031e0f8420322ab3afaf44ff4e4e21400612d0e6682537ab1fa04cb3b583f340` |
