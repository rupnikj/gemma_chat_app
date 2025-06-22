import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

class TtsService {
  static const String _modelAssetPath = 'assets/kokoro-int8-en-v0_19/model.int8.onnx';
  static const String _tokensAssetPath = 'assets/kokoro-int8-en-v0_19/tokens.txt';
  static const String _voicesAssetPath = 'assets/kokoro-int8-en-v0_19/voices.bin';
  static const String _dataDirAssetPath = 'assets/kokoro-int8-en-v0_19/espeak-ng-data/';

  sherpa_onnx.OfflineTts? _tts;
  bool _isInitialized = false;
  
  final ValueNotifier<bool> isInitialized = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isProcessing = ValueNotifier<bool>(false);
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  /// Initialize the TTS service by setting up sherpa-onnx bindings and loading the model
  Future<void> initialize() async {
    try {
      lastError.value = null;
      
      // Initialize sherpa-onnx bindings for Android
      _initSherpaOnnxBindings();
      
      // Copy assets to local storage and get their paths
      final modelPaths = await _copyAssetsToLocal();
      
      // Create the Kokoro model configuration
      final kokoro = sherpa_onnx.OfflineTtsKokoroModelConfig(
        model: modelPaths['model']!,
        voices: modelPaths['voices']!,
        tokens: modelPaths['tokens']!,
        dataDir: modelPaths['dataDir']!,
        lengthScale: 1.0, // Default speed
      );

      // Create the model configuration
      final modelConfig = sherpa_onnx.OfflineTtsModelConfig(
        kokoro: kokoro,
        numThreads: 2, // Use 2 threads for better performance
        debug: false,
      );

      // Create the TTS configuration
      final config = sherpa_onnx.OfflineTtsConfig(
        model: modelConfig,
        maxNumSenetences: 1, // kokoro needs 1
        ruleFsts: '',
        ruleFars: '',
      );
      
      // Create the TTS instance
      _tts = sherpa_onnx.OfflineTts(config);
      
      _isInitialized = true;
      isInitialized.value = true;
      
      debugPrint('[TtsService] Successfully initialized TTS service');
    } catch (e) {
      final errorMsg = 'Failed to initialize TTS service: $e';
      debugPrint('[TtsService] $errorMsg');
      lastError.value = errorMsg;
      _isInitialized = false;
      isInitialized.value = false;
      rethrow;
    }
  }

  /// Initialize sherpa-onnx bindings for the current platform
  void _initSherpaOnnxBindings() {
    try {
      // For Android, we don't need to specify a path as the library
      // should be bundled with the app
      sherpa_onnx.initBindings();
      debugPrint('[TtsService] Sherpa-ONNX bindings initialized');
    } catch (e) {
      debugPrint('[TtsService] Failed to initialize sherpa-onnx bindings: $e');
      rethrow;
    }
  }

  /// Copy model assets from bundle to local storage
  Future<Map<String, String>> _copyAssetsToLocal() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final modelsDir = Directory(path.join(appDir.path, 'sherpa_onnx_tts_models'));
      
      if (!await modelsDir.exists()) {
        await modelsDir.create(recursive: true);
      }

      final Map<String, String> localPaths = {};

      // Copy individual files
      final filesToCopy = {
        'model': _modelAssetPath,
        'tokens': _tokensAssetPath,
        'voices': _voicesAssetPath,
      };

      for (final entry in filesToCopy.entries) {
        final assetKey = entry.key;
        final assetPath = entry.value;
        final fileName = path.basename(assetPath);
        final localPath = path.join(modelsDir.path, fileName);
        
        // Check if file already exists
        final localFile = File(localPath);
        if (!await localFile.exists()) {
          debugPrint('[TtsService] Copying $assetPath to $localPath');
          final byteData = await rootBundle.load(assetPath);
          final bytes = byteData.buffer.asUint8List();
          await localFile.writeAsBytes(bytes);
        } else {
          debugPrint('[TtsService] File $localPath already exists, skipping copy');
        }
        
        localPaths[assetKey] = localPath;
      }

      // Copy espeak-ng-data directory
      final dataDirPath = path.join(modelsDir.path, 'espeak-ng-data');
      final dataDirLocal = Directory(dataDirPath);
      if (!await dataDirLocal.exists()) {
        await dataDirLocal.create(recursive: true);
        await _copyAssetDirectory(_dataDirAssetPath, dataDirPath);
      }
      localPaths['dataDir'] = dataDirPath;

      return localPaths;
    } catch (e) {
      debugPrint('[TtsService] Failed to copy assets to local storage: $e');
      rethrow;
    }
  }

  /// Copy an entire asset directory to local storage
  Future<void> _copyAssetDirectory(String assetDirPath, String localDirPath) async {
    try {
      // Get the asset manifest to find all files in the espeak-ng-data directory
      final manifestContent = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifestMap = json.decode(manifestContent);

      // Find all assets that start with our asset directory path
      final assetFiles = manifestMap.keys
          .where((String key) => key.startsWith(assetDirPath))
          .where((String key) => !key.endsWith('/')) // Skip directories
          .toList();

      debugPrint('[TtsService] Found ${assetFiles.length} files in $assetDirPath');

      // Copy each file
      for (final assetPath in assetFiles) {
        final relativePath = assetPath.substring(assetDirPath.length);
        final localFilePath = path.join(localDirPath, relativePath);
        
        // Create directory if needed
        final localFile = File(localFilePath);
        await localFile.parent.create(recursive: true);
        
        // Copy file if it doesn't exist
        if (!await localFile.exists()) {
          try {
            final byteData = await rootBundle.load(assetPath);
            final bytes = byteData.buffer.asUint8List();
            await localFile.writeAsBytes(bytes);
            debugPrint('[TtsService] Copied $assetPath to $localFilePath');
          } catch (e) {
            debugPrint('[TtsService] Warning: Could not copy $assetPath: $e');
            // Continue with other files
          }
        }
      }
      
      debugPrint('[TtsService] Completed copying espeak-ng-data directory to $localDirPath');
      
    } catch (e) {
      debugPrint('[TtsService] Warning: Could not copy espeak-ng-data directory: $e');
      // Continue anyway as some TTS models might work without this data
    }
  }



  /// Generate speech and save to file (non-blocking)
  Future<String> generateSpeechToFile({
    required String text,
    required String outputPath,
    double speed = 1.0,
    int speakerId = 0,
  }) async {
    if (!_isInitialized) {
      throw StateError('TTS service is not initialized. Call initialize() first.');
    }

    try {
      isProcessing.value = true;
      lastError.value = null;
      
      // Optimize text for better performance
      final optimizedText = _optimizeTextForTts(text);
      
      debugPrint('[TtsService] Starting non-blocking TTS generation for: "${optimizedText.substring(0, optimizedText.length > 50 ? 50 : optimizedText.length)}..."');
      
      // Run TTS generation in a separate isolate to avoid blocking the main thread
      await compute(_generateTtsInIsolate, {
        'text': optimizedText,
        'outputPath': outputPath,
        'speed': speed,
        'speakerId': speakerId,
        'modelPaths': await _getModelPaths(),
      });

      debugPrint('[TtsService] Completed non-blocking TTS generation and saved to $outputPath');
      return outputPath;
    } catch (e) {
      final errorMsg = 'Failed to generate speech to file: $e';
      debugPrint('[TtsService] $errorMsg');
      lastError.value = errorMsg;
      rethrow;
    } finally {
      isProcessing.value = false;
    }
  }

  /// Get the current model paths for isolate usage
  Future<Map<String, String>> _getModelPaths() async {
    final appDir = await getApplicationDocumentsDirectory();
    final modelsDir = Directory(path.join(appDir.path, 'sherpa_onnx_tts_models'));
    
    return {
      'model': path.join(modelsDir.path, 'model.int8.onnx'),
      'tokens': path.join(modelsDir.path, 'tokens.txt'),
      'voices': path.join(modelsDir.path, 'voices.bin'),
      'dataDir': path.join(modelsDir.path, 'espeak-ng-data'),
    };
  }

  /// Optimize text for TTS by limiting length and cleaning up formatting
  String _optimizeTextForTts(String text) {
    // Remove excessive whitespace and clean up text
    String cleanText = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    
    // Limit text length to avoid very long generation times
    const maxLength = 200; // Reduced to prevent ANR issues
    if (cleanText.length > maxLength) {
      // Find a good breaking point (end of sentence, paragraph, etc.)
      int breakPoint = maxLength;
      final sentenceEnd = cleanText.lastIndexOf('.', maxLength);
      final questionEnd = cleanText.lastIndexOf('?', maxLength);
      final exclamationEnd = cleanText.lastIndexOf('!', maxLength);
      
      final bestBreak = [sentenceEnd, questionEnd, exclamationEnd]
          .where((i) => i > maxLength * 0.7) // At least 70% of max length
          .fold(-1, (max, current) => current > max ? current : max);
      
      if (bestBreak > 0) {
        breakPoint = bestBreak + 1;
      }
      
      cleanText = cleanText.substring(0, breakPoint).trim();
      debugPrint('[TtsService] Text truncated to $breakPoint characters for performance');
    }
    
    return cleanText;
  }

  /// Get available speaker IDs (for multi-speaker models)
  List<int> getAvailableSpeakers() {
    // Kokoro typically supports multiple speakers
    // This is a placeholder - you might want to make this configurable
    return List.generate(10, (index) => index); // Speakers 0-9
  }

  /// Check if the service is ready to use
  bool get isReady => _isInitialized;

  /// Clean up resources
  void dispose() {
    try {
      _tts?.free();
      _tts = null;
      _isInitialized = false;
      isInitialized.value = false;
      isProcessing.value = false;
      lastError.value = null;
      debugPrint('[TtsService] Disposed TTS service');
    } catch (e) {
      debugPrint('[TtsService] Error during disposal: $e');
    }
  }
}

/// Top-level function for running TTS generation in an isolate
/// This must be a top-level function to work with compute()
Future<void> _generateTtsInIsolate(Map<String, dynamic> params) async {
  final text = params['text'] as String;
  final outputPath = params['outputPath'] as String;
  final speed = params['speed'] as double;
  final speakerId = params['speakerId'] as int;
  final modelPaths = params['modelPaths'] as Map<String, String>;

  try {
    // Initialize sherpa-onnx bindings in the isolate
    sherpa_onnx.initBindings();

    // Create the Kokoro model configuration
    final kokoro = sherpa_onnx.OfflineTtsKokoroModelConfig(
      model: modelPaths['model']!,
      voices: modelPaths['voices']!,
      tokens: modelPaths['tokens']!,
      dataDir: modelPaths['dataDir']!,
      lengthScale: 1.0,
    );

    // Create the model configuration
    final modelConfig = sherpa_onnx.OfflineTtsModelConfig(
      kokoro: kokoro,
      numThreads: 2,
      debug: false,
    );

    // Create the TTS configuration
    final config = sherpa_onnx.OfflineTtsConfig(
      model: modelConfig,
      maxNumSenetences: 1,
      ruleFsts: '',
      ruleFars: '',
    );

    // Create the TTS instance
    final tts = sherpa_onnx.OfflineTts(config);

    // Generate audio
    final audio = tts.generate(
      text: text,
      sid: speakerId,
      speed: speed,
    );

    // Save to file
    sherpa_onnx.writeWave(
      filename: outputPath,
      samples: audio.samples,
      sampleRate: audio.sampleRate,
    );

    // Clean up
    tts.free();

    print('[TtsService] Isolate: Generated and saved TTS audio to $outputPath');
  } catch (e) {
    print('[TtsService] Isolate: Error generating TTS: $e');
    rethrow;
  }
} 