# Murmur

Private voice typing for your Mac. Hold **Fn**, speak, let go, and cleaned-up text appears wherever your cursor is.

Speech recognition and cleanup run on your Mac. Nothing you say leaves it unless you turn on Cloud boost.

## Features

- **Hold Fn** for English (NVIDIA Parakeet). **Fn + Shift** for Hindi and Hinglish (Whisper large-v3-turbo).
- **Double-tap Fn** for hands-free. **Esc** cancels.
- **Built-in cleanup** with Qwen3 4B via llama.cpp: removes fillers, fixes punctuation and applies "no wait, I mean…" corrections.
- Models download inside the app from **Get started**, with progress, resume and checksum verification.
- Optional cleanup through Ollama or a cloud API (Anthropic). Optional cloud speech (Groq, Sarvam).
- Personal dictionary, snippets, per-app rules and a 7-day history.

## Requirements

Apple Silicon Mac, macOS 26 or later.

## Install

1. Download `Murmur-0.2.0.dmg` from Releases and drag Murmur to Applications.
2. Open Murmur. macOS will say it can't check it for malicious software. Click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Murmur.
4. Follow **Get started**: download a speech model, choose cleanup, and grant Microphone, Accessibility and Input Monitoring.
5. In **System Settings → Keyboard**, set "Press 🌐 key to" to **Do Nothing**.

## Build from source

Requires the Xcode Command Line Tools (`xcode-select --install`).

```bash
swift test
scripts/bundle.sh          # builds and signs build/Murmur.app
scripts/make-dmg.sh        # builds build/Murmur-<version>.dmg
```

`scripts/create-signing-identity.sh` creates a local self-signed code-signing certificate. With it, macOS keeps Murmur's permissions across rebuilds.

## Licence

Murmur © 2026 Muhamed Shibili · https://shibili.works/

Third-party components and model licences are listed in [Resources/THIRD_PARTY_NOTICES.txt](Resources/THIRD_PARTY_NOTICES.txt).
