import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma/core/chat.dart'; // Explicit import for InferenceChat
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
// It's good practice to also import the core types if you use them directly.
import 'package:flutter_gemma/core/model.dart';
// import 'package:flutter_gemma/core/message.dart'; // Unnecessary import
import 'package:flutter_gemma/pigeon.g.dart' show PreferredBackend;

class ChatService {
  final FlutterGemmaPlugin _gemma = FlutterGemmaPlugin.instance;
  InferenceModel? _inferenceModel;
  InferenceChat? _chat;

  // Default configuration values
  static const int _defaultMaxTokens = 4096;
  static const PreferredBackend _defaultBackend = PreferredBackend.cpu;
  static const double _defaultTemperature = 1.0;
  static const int _defaultTopK = 64;
  static const double _defaultTopP = 0.95;

  final ValueNotifier<bool> isModelReady = ValueNotifier<bool>(false);
  final ValueNotifier<String?> currentModelPath = ValueNotifier<String?>(null);

  // Configuration ValueNotifiers
  final ValueNotifier<int> maxTokens = ValueNotifier<int>(_defaultMaxTokens);
  final ValueNotifier<PreferredBackend> preferredBackend =
      ValueNotifier<PreferredBackend>(_defaultBackend);
  final ValueNotifier<double> temperature = ValueNotifier<double>(
    _defaultTemperature,
  );
  final ValueNotifier<int> topK = ValueNotifier<int>(_defaultTopK);
  final ValueNotifier<double> topP = ValueNotifier<double>(_defaultTopP);

  // SharedPreferences keys
  static const String _modelPathKey = 'gemma_model_path';
  static const String _maxTokensKey = 'gemma_max_tokens';
  static const String _backendKey = 'gemma_backend';
  static const String _temperatureKey = 'gemma_temperature';
  static const String _topKKey = 'gemma_top_k';
  static const String _topPKey = 'gemma_top_p';

  final ModelType _modelType =
      ModelType.gemmaIt; // Default, can be made configurable

  // --- Methods will be implemented below ---

  Future<void> initialize() async {
    final prefs = await _prefs;

    // Load all configurations
    maxTokens.value = prefs.getInt(_maxTokensKey) ?? _defaultMaxTokens;
    final backendString =
        prefs.getString(_backendKey) ??
        (_defaultBackend == PreferredBackend.cpu ? 'cpu' : 'gpu');
    preferredBackend.value =
        backendString == 'cpu' ? PreferredBackend.cpu : PreferredBackend.gpu;
    temperature.value = prefs.getDouble(_temperatureKey) ?? _defaultTemperature;
    topK.value = prefs.getInt(_topKKey) ?? _defaultTopK;
    topP.value = prefs.getDouble(_topPKey) ?? _defaultTopP;

    final String? savedPath = prefs.getString(_modelPathKey);
    if (savedPath != null && savedPath.isNotEmpty) {
      print('Found saved model path: $savedPath');
      try {
        await _loadModelFromPath(
          savedPath,
          modelType: _modelType,
          preferredBackend: preferredBackend.value,
        );
      } catch (e) {
        print('Error loading model from saved path: $e');
        // Optionally clear the saved path if loading fails
        // await prefs.remove(_modelPathKey);
        // currentModelPath.value = null;
        // isModelReady.value = false;
      }
    } else {
      print('No saved model path found.');
    }
  }

  Future<void> updateMaxTokens(int newMaxTokens) async {
    if (newMaxTokens < 512 || newMaxTokens > 4096) {
      throw ArgumentError('Max tokens must be between 512 and 4096');
    }

    maxTokens.value = newMaxTokens;
    final prefs = await _prefs;
    await prefs.setInt(_maxTokensKey, newMaxTokens);

    // Reload model if it's currently loaded
    if (isModelReady.value && currentModelPath.value != null) {
      await _loadModelFromPath(
        currentModelPath.value!,
        modelType: _modelType,
        preferredBackend: preferredBackend.value,
      );
    }
  }

  Future<void> updateBackend(PreferredBackend newBackend) async {
    preferredBackend.value = newBackend;
    final prefs = await _prefs;
    await prefs.setString(
      _backendKey,
      newBackend == PreferredBackend.cpu ? 'cpu' : 'gpu',
    );

    // Reload model if it's currently loaded
    if (isModelReady.value && currentModelPath.value != null) {
      await _loadModelFromPath(
        currentModelPath.value!,
        modelType: _modelType,
        preferredBackend: newBackend,
      );
    }
  }

  Future<void> updateChatParameters({
    double? newTemperature,
    int? newTopK,
    double? newTopP,
  }) async {
    bool needsRecreate = false;
    final prefs = await _prefs;

    if (newTemperature != null) {
      if (newTemperature < 0 || newTemperature > 2) {
        throw ArgumentError('Temperature must be between 0 and 2');
      }
      temperature.value = newTemperature;
      await prefs.setDouble(_temperatureKey, newTemperature);
      needsRecreate = true;
    }

    if (newTopK != null) {
      if (newTopK < 1) {
        throw ArgumentError('TopK must be >= 1');
      }
      topK.value = newTopK;
      await prefs.setInt(_topKKey, newTopK);
      needsRecreate = true;
    }

    if (newTopP != null) {
      if (newTopP < 0 || newTopP > 1) {
        throw ArgumentError('TopP must be between 0 and 1');
      }
      topP.value = newTopP;
      await prefs.setDouble(_topPKey, newTopP);
      needsRecreate = true;
    }

    // Recreate chat if model is ready and parameters changed
    if (needsRecreate && _inferenceModel != null) {
      await _recreateChat();
    }
  }

  Future<void> _recreateChat() async {
    if (_inferenceModel == null) {
      print("Cannot recreate chat: InferenceModel is null.");
      return;
    }

    // If there's an existing chat session, close it before creating a new one.
    if (_chat != null && _chat!.session != null) {
      print("Closing existing chat session before recreating...");
      try {
        await _chat!.session.close();
        print("Existing chat session closed successfully.");
      } catch (e) {
        print("Error closing existing chat session: $e");
      }
    }

    print('Recreating chat with new parameters...');
    try {
      _chat = await _inferenceModel!.createChat(
        temperature: temperature.value,
        topK: topK.value,
        topP: topP.value,
      );
      print('Chat recreated successfully with new parameters.');
    } catch (e) {
      print("Error during _inferenceModel.createChat: $e");
      rethrow;
    }
  }

  Future<void> pickAndLoadModel({
    ModelType modelType = ModelType.gemmaIt,
    PreferredBackend? preferredBackend,
  }) async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type:
            FileType
                .any, // Or be more specific if model files have a common extension
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        String filePath = result.files.single.path!;
        print('File picked: $filePath');
        // You might want to add checks here for file type or size if necessary
        await _loadModelFromPath(
          filePath,
          modelType: modelType,
          preferredBackend: preferredBackend ?? this.preferredBackend.value,
        );
      } else {
        print('File picking cancelled or path is null.');
        // User canceled the picker or something went wrong
      }
    } catch (e) {
      print('Error picking file: $e');
      // Handle error (e.g., show a message to the user)
      isModelReady.value = false;
      currentModelPath.value = null;
      // Optionally, rethrow or handle more gracefully
    }
  }

  Future<void> _loadModelFromPath(
    String path, {
    required ModelType modelType,
    PreferredBackend? preferredBackend,
  }) async {
    if (_inferenceModel != null) {
      print('Closing existing model before loading a new one.');
      await _inferenceModel!.close();
      _inferenceModel = null;
      _chat = null;
      isModelReady.value = false;
    }

    currentModelPath.value =
        path; // Update path optimistically or after successful load
    print('Attempting to load model from: $path');

    try {
      // This step makes the model file available to the plugin.
      // For native platforms, this might involve telling the native side where the file is.
      // For web, this path might be a URL.
      await _gemma.modelManager.setModelPath(path);

      if (await _gemma.modelManager.isModelInstalled) {
        print('Model is confirmed as installed by manager at path: $path');
        _inferenceModel = await _gemma.createModel(
          modelType: modelType,
          maxTokens: maxTokens.value, // Use configured maxTokens
          preferredBackend:
              preferredBackend ??
              this.preferredBackend.value, // Use configured preferredBackend
        );
        print('InferenceModel created.');

        // Create a chat session with current parameters
        _chat = await _inferenceModel!.createChat(
          temperature: temperature.value,
          topK: topK.value,
          topP: topP.value,
        );
        print('InferenceChat session created.');

        isModelReady.value = true;
        final prefs = await _prefs;
        await prefs.setString(
          _modelPathKey,
          path,
        ); // Save path on successful load
        print('Model loaded successfully from $path and path saved.');
      } else {
        print(
          'Model manager reports model not installed at path: $path after setModelPath.',
        );
        // This case might indicate an issue with setModelPath or the file itself.
        isModelReady.value = false;
        currentModelPath.value = null; // Revert path if load failed
        final prefs = await _prefs;
        await prefs.remove(_modelPathKey); // Remove invalid path
        throw Exception(
          "Model not installed after setting path. Check file validity and permissions.",
        );
      }
    } catch (e) {
      print('Error during _loadModelFromPath: $e');
      isModelReady.value = false;
      currentModelPath.value = null;
      // Optionally remove the path from prefs if loading fails critically
      // final prefs = await _prefs;
      // await prefs.remove(_modelPathKey);
      rethrow; // Rethrow to allow UI to handle it
    }
  }

  Stream<String> sendMessage(String text) async* {
    if (!isModelReady.value || _chat == null) {
      print('Chat service is not ready or chat session is null.');
      // Return an error stream or throw an exception
      throw Exception("Model not loaded or chat session not initialized.");
    }

    // Properly await addQueryChunk before calling generateChatResponseAsync
    // This prevents the "Previous invocation still processing" error
    final message = Message(text: text, isUser: true);
    await _chat!.addQueryChunk(message);
    yield* _chat!.generateChatResponseAsync();
  }

  Future<void> restartChat() async {
    if (_chat != null) {
      print('Restarting chat session (clearing history).');
      await _chat!.clearHistory();
      // clearHistory in flutter_gemma's InferenceChat should re-initialize the session.
      print('Chat history cleared.');
    } else {
      print('Chat session not initialized, cannot restart.');
      // Optionally, if _inferenceModel exists, you could recreate _chat here
      // if a model is loaded but the chat object was somehow lost.
      // if (_inferenceModel != null) { ... _chat = await _inferenceModel.createChat(...) ... }
    }
  }

  List<Message> getChatHistory() {
    return _chat?.fullHistory ?? [];
  }

  Future<void> removeModel() async {
    print('Removing model...');
    if (_inferenceModel != null) {
      await _inferenceModel!.close();
      _inferenceModel = null;
      print('InferenceModel closed.');
    }
    _chat = null; // Chat is tied to the inference model

    // According to flutter_gemma docs, deleteModel also closes inference if initialized.
    // However, we closed it above explicitly for clarity and control.
    // This call is more about the ModelFileManager forgetting the model or deleting stored files if any.
    await _gemma.modelManager.deleteModel();
    print('Model deleted from manager.');

    final prefs = await _prefs;
    await prefs.remove(_modelPathKey);
    print('Model path removed from preferences.');

    isModelReady.value = false;
    currentModelPath.value = null;
    print('ChatService state reset after model removal.');
  }

  // Helper to get an instance of SharedPreferences
  Future<SharedPreferences> get _prefs async => SharedPreferences.getInstance();

  // --- End of Methods ---
}
