import 'dart:async';
import 'dart:math'; // Added for Random
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

  // Track generation state for stop functionality
  bool _isGenerating = false;
  StreamController<String>? _currentStreamController;

  // Default configuration values
  static const int _defaultMaxTokens = 4096;
  static const PreferredBackend _defaultBackend = PreferredBackend.cpu;
  static const double _defaultTemperature = 1.0;
  static const int _defaultTopK = 64;
  static const double _defaultTopP = 0.95;
  static const int _defaultRandomSeed = 1;
  static const bool _defaultUseFixedRandomSeed = false;

  final ValueNotifier<bool> isModelReady = ValueNotifier<bool>(false);
  final ValueNotifier<String?> currentModelPath = ValueNotifier<String?>(null);
  final ValueNotifier<bool> isGenerating = ValueNotifier<bool>(false);
  final ValueNotifier<int> historyVersion = ValueNotifier<int>(0); // To trigger UI updates when history changes

  // Configuration ValueNotifiers
  final ValueNotifier<int> maxTokens = ValueNotifier<int>(_defaultMaxTokens);
  final ValueNotifier<PreferredBackend> preferredBackend =
      ValueNotifier<PreferredBackend>(_defaultBackend);
  final ValueNotifier<double> temperature = ValueNotifier<double>(
    _defaultTemperature,
  );
  final ValueNotifier<int> topK = ValueNotifier<int>(_defaultTopK);
  final ValueNotifier<double> topP = ValueNotifier<double>(_defaultTopP);
  final ValueNotifier<int?> randomSeed = ValueNotifier<int?>(
    _defaultRandomSeed,
  );
  final ValueNotifier<bool> useFixedRandomSeed = ValueNotifier<bool>(
    _defaultUseFixedRandomSeed,
  );

  // SharedPreferences keys
  static const String _modelPathKey = 'gemma_model_path';
  static const String _maxTokensKey = 'gemma_max_tokens';
  static const String _backendKey = 'gemma_backend';
  static const String _temperatureKey = 'gemma_temperature';
  static const String _topKKey = 'gemma_top_k';
  static const String _topPKey = 'gemma_top_p';
  static const String _randomSeedKey = 'gemma_random_seed';
  static const String _useFixedRandomSeedKey = 'gemma_use_fixed_random_seed';

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
    randomSeed.value = prefs.getInt(_randomSeedKey) ?? _defaultRandomSeed;
    useFixedRandomSeed.value =
        prefs.getBool(_useFixedRandomSeedKey) ?? _defaultUseFixedRandomSeed;

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
        // Clear the saved path if loading fails
        await prefs.remove(_modelPathKey);
        currentModelPath.value = null;
        isModelReady.value = false;
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

  Future<void> updateRandomSeedSettings({int? newSeed, bool? useFixed}) async {
    bool needsRecreate = false;
    final prefs = await _prefs;

    if (useFixed != null && useFixedRandomSeed.value != useFixed) {
      useFixedRandomSeed.value = useFixed;
      await prefs.setBool(_useFixedRandomSeedKey, useFixed);
      needsRecreate = true;
    }

    if (newSeed != null && randomSeed.value != newSeed) {
      if (newSeed < 1) {
        // Assuming seed should be positive, adjust if necessary
        throw ArgumentError('Random seed must be >= 1');
      }
      randomSeed.value = newSeed;
      await prefs.setInt(_randomSeedKey, newSeed);
      needsRecreate = true;
    } else if (useFixed == false) {
      // If switching to dynamic seed, clear the stored fixed seed value
      // Or set it to default; here we'll clear for explicitness
      // await prefs.remove(_randomSeedKey);
      // randomSeed.value = null; // Or _defaultRandomSeed if preferred when fixed is off
    }

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
    if (_chat != null) {
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
      final currentSeed =
          useFixedRandomSeed.value
              ? (randomSeed.value ?? _defaultRandomSeed)
              : Random().nextInt(1 << 30); // Generate a random int if not fixed

      _chat = await _inferenceModel!.createChat(
        temperature: temperature.value,
        topK: topK.value,
        topP: topP.value,
        randomSeed: currentSeed,
      );
      print(
        'Chat recreated successfully. Seed: $currentSeed, Temp: ${temperature.value}, TopK: ${topK.value}, TopP: ${topP.value}',
      );
    } catch (e) {
      print("Error during _inferenceModel.createChat: $e");
      rethrow;
    }
  }

  Future<void> _recreateChatWithHistory(List<Message> history) async {
    if (_inferenceModel == null) {
      print("Cannot recreate chat: InferenceModel is null.");
      return;
    }

    // If there's an existing chat session, close it before creating a new one.
    if (_chat != null) {
      print("Closing existing chat session before recreating with history...");
      try {
        await _chat!.session.close();
        print("Existing chat session closed successfully.");
      } catch (e) {
        print("Error closing existing chat session: $e");
      }
    }

    print('Recreating chat with history (${history.length} messages)...');
    try {
      final currentSeed =
          useFixedRandomSeed.value
              ? (randomSeed.value ?? _defaultRandomSeed)
              : Random().nextInt(1 << 30); // Generate a random int if not fixed

      _chat = await _inferenceModel!.createChat(
        temperature: temperature.value,
        topK: topK.value,
        topP: topP.value,
        randomSeed: currentSeed,
      );

      // Add each message back to the chat history
      for (final message in history) {
        await _chat!.addQueryChunk(message);
      }

      print(
        'Chat recreated with history successfully. Messages: ${history.length}, Seed: $currentSeed',
      );
    } catch (e) {
      print("Error during _recreateChatWithHistory: $e");
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
      // Clear any previously cached model to ensure clean state
      await _gemma.modelManager.deleteModel();
      print('Cleared any previously cached model');
      
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
          randomSeed:
              useFixedRandomSeed.value
                  ? randomSeed.value ?? _defaultRandomSeed
                  : Random().nextInt(
                    1 << 30,
                  ), // Generate a random int if not fixed
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
      // Remove the path from prefs if loading fails critically
      final prefs = await _prefs;
      await prefs.remove(_modelPathKey);
      rethrow; // Rethrow to allow UI to handle it
    }
  }

  Stream<String> sendMessage(String text) async* {
    if (!isModelReady.value || _chat == null) {
      print('Chat service is not ready or chat session is null.');
      throw Exception("Model not loaded or chat session not initialized.");
    }

    if (_isGenerating) {
      print('Generation already in progress.');
      throw Exception("Generation already in progress.");
    }

    _isGenerating = true;
    isGenerating.value = true;
    
    // Create a new stream controller for this generation
    _currentStreamController = StreamController<String>();
    
    try {
      // Properly await addQueryChunk before calling generateChatResponseAsync
      final message = Message(text: text, isUser: true);
      await _chat!.addQueryChunk(message);
      
      // Debug print after adding user message
      print('User message added to chat history');
      debugPrintHistory();
      
      // Start the generation stream
      final responseStream = _chat!.generateChatResponseAsync();
      
      await for (final token in responseStream) {
        if (!_isGenerating) {
          // Generation was stopped
          print('Generation stopped by user');
          break;
        }
        
        _currentStreamController?.add(token);
        yield token;
      }
    } catch (e) {
      print('Error during message generation: $e');
      
      // Check if this is a MediaPipe timestamp error and try to recover
      if (e.toString().contains('Packet timestamp mismatch') || 
          e.toString().contains('Previous invocation still processing')) {
        print('MediaPipe session error detected, attempting to recreate chat session...');
        try {
          await _recreateChat();
          print('Chat session recreated successfully after error');
          throw Exception("MediaPipe session error. Chat session has been reset. Please try again.");
        } catch (recreateError) {
          print('Failed to recreate chat session: $recreateError');
          throw Exception("MediaPipe session error and failed to recover. Please restart the chat manually.");
        }
      }
      
      rethrow;
    } finally {
      _isGenerating = false;
      isGenerating.value = false;
      _currentStreamController?.close();
      _currentStreamController = null;
    }
  }

  Future<void> restartChat() async {
    if (_inferenceModel == null) {
      print(
        'Cannot restart chat: InferenceModel is null. Model needs to be loaded.',
      );
      // Optionally, throw an error or notify the user that the model isn't loaded.
      // For example, you could throw an Exception:
      // throw Exception("Model not loaded. Cannot restart chat.");
      return; // Or handle this scenario appropriately in the UI
    }

    print('Restarting chat session by recreating it...');
    try {
      await _recreateChat(); // This will handle seed generation correctly.
      print('Chat session restarted successfully by recreating.');
    } catch (e) {
      print('Error during chat restart (recreation): $e');
      // Rethrow or handle as appropriate for your app's error handling strategy
      rethrow;
    }
  }

  List<Message> getChatHistory() {
    return _chat?.fullHistory ?? [];
  }

  /// Stop the current generation if it's in progress
  /// This is Android-only functionality
  Future<void> stopGeneration() async {
    if (!_isGenerating || _chat == null) {
      print('No generation in progress to stop.');
      return;
    }

    try {
      print('Stopping generation...');
      // Call the new cancelGenerateResponseAsync method
      await _chat!.cancelGenerateResponseAsync();
      print('Generation stopped successfully');
    } catch (e) {
      print('Error stopping generation: $e');
      
      // Check if this is a MediaPipe session error
      if (e.toString().contains('Packet timestamp mismatch') || 
          e.toString().contains('Previous invocation still processing')) {
        print('MediaPipe session error during stop, attempting to recreate chat session...');
        try {
          await _recreateChat();
          print('Chat session recreated successfully after stop error');
        } catch (recreateError) {
          print('Failed to recreate chat session after stop error: $recreateError');
        }
      }
      
      // Even if there's an error, we should still update our state
    } finally {
      _isGenerating = false;
      isGenerating.value = false;
      _currentStreamController?.close();
      _currentStreamController = null;
    }
  }

  /// Check if generation is currently in progress
  bool get isCurrentlyGenerating => _isGenerating;

  /// Edit a message in the chat history by index
  Future<void> editMessageByIndex(int messageIndex, String newText) async {
    if (_chat == null) {
      throw Exception("Chat session not initialized.");
    }

    // Get the current history
    final currentHistory = _chat!.fullHistory;
    
    // Debug print the history before editing
    debugPrintHistory();
    
    if (messageIndex < 0 || messageIndex >= currentHistory.length) {
      throw Exception("Message index $messageIndex is out of bounds. History has ${currentHistory.length} messages.");
    }
    
    final messageToEdit = currentHistory[messageIndex];
    print('Editing message at index $messageIndex: "${messageToEdit.text}" -> "$newText"');
    
    // Create a new modifiable list with the edited message
    final newHistory = <Message>[];
    for (int i = 0; i < currentHistory.length; i++) {
      if (i == messageIndex) {
        // Create a new message with the edited text but preserve other properties
        newHistory.add(Message(
          text: newText,
          isUser: messageToEdit.isUser,
        ));
      } else {
        // Keep the original message
        newHistory.add(currentHistory[i]);
      }
    }
    
    // Recreate the chat session with the new history
    await _recreateChatWithHistory(newHistory);
    
    // Trigger UI update by incrementing history version
    historyVersion.value++;
    
    // Debug print the history after editing
    print('Message edited successfully');
    debugPrintHistory();
  }

  /// Debug print the entire chat history with raw message data
  void debugPrintHistory() {
    final history = _chat?.fullHistory ?? [];
    print('=== CHAT HISTORY DEBUG ===');
    print('Total messages: ${history.length}');
    
    for (int i = 0; i < history.length; i++) {
      final message = history[i];
      print('[$i] User: ${message.isUser}');
      print('    Text: "${message.text}"');
      print('    ---');
    }
    print('=== END CHAT HISTORY ===');
  }

  /// Delete a message from the chat history by index
  Future<void> deleteMessageByIndex(int messageIndex) async {
    if (_chat == null) {
      throw Exception("Chat session not initialized.");
    }

    // Get the current history
    final currentHistory = _chat!.fullHistory;
    
    // Debug print the history before deleting
    debugPrintHistory();
    
    if (messageIndex < 0 || messageIndex >= currentHistory.length) {
      throw Exception("Message index $messageIndex is out of bounds. History has ${currentHistory.length} messages.");
    }
    
    print('Deleting message at index $messageIndex: "${currentHistory[messageIndex].text}"');
    
    // Create a new modifiable list without the deleted message
    final newHistory = <Message>[];
    for (int i = 0; i < currentHistory.length; i++) {
      if (i != messageIndex) {
        newHistory.add(currentHistory[i]);
      }
    }
    
    // Recreate the chat session with the new history
    await _recreateChatWithHistory(newHistory);
    
    // Debug print the history after deleting
    print('Message deleted successfully');
    debugPrintHistory();
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
