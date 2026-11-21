# Whisper translate-task probe (manual)
Use large-v3 (NOT turbo; turbo was fine-tuned without translation data, openai/whisper discussion #2363).
WhisperKit: DecodingOptions(task: .translate, language: "<src>") with a large-v3 CoreML variant; compare with transcribe + Apple Translation on the same clip.
