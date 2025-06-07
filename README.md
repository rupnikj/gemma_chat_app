# Gemma Chat App

A Flutter application for chatting with Google's Gemma AI model locally on your device.

## Features

- **Local AI Chat**: Run Gemma AI models directly on your device
- **Model Management**: Pick and load different Gemma model files
- **Configurable Settings**: Adjust temperature, top-k, top-p, and other parameters
- **Chat History**: Persistent conversation history
- **Stop Generation** (Android only): Stop AI response generation mid-stream

## Stop Generation Feature

The app now supports stopping AI text generation while it's in progress. This feature is currently available on Android only.

### How it works:
- When the AI is generating a response, a red "Stop" button appears next to the send button
- Clicking the stop button immediately halts generation
- The partial response generated so far is preserved and added to the chat history
- The conversation can continue normally after stopping

### Platform Support:
- ✅ **Android**: Full support via MediaPipe
- ❌ **iOS**: Not supported (requires MediaPipe iOS implementation)
- ❌ **Web**: Not supported (requires web-specific implementation)

## Dependencies

This app uses the updated `flutter_gemma` plugin from [rupnikj/flutter_gemma](https://github.com/rupnikj/flutter_gemma) which includes the stop generation functionality.

## Getting Started

1. Clone this repository
2. Run `flutter pub get` to install dependencies
3. Build and run the app: `flutter run`
4. Use the folder icon to pick a Gemma model file
5. Start chatting with the AI
6. On Android, use the stop button to halt generation if needed

## Model Files

You'll need to provide your own Gemma model files. The app supports various Gemma model formats including:
- Gemma 2B & 7B
- Gemma-2 2B  
- Gemma-3 1B
- Gemma 3 Nano 2B & 4B
- And other compatible models

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
