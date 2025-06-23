import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
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
      
      // Create the Kokoro model configuration optimized for speed
      final kokoro = sherpa_onnx.OfflineTtsKokoroModelConfig(
        model: modelPaths['model']!,
        voices: modelPaths['voices']!,
        tokens: modelPaths['tokens']!,
        dataDir: modelPaths['dataDir']!,
        lengthScale: 0.8, // Slightly faster speed for lower latency
      );

      // Create the model configuration optimized for speed
      final modelConfig = sherpa_onnx.OfflineTtsModelConfig(
        kokoro: kokoro,
        numThreads: 4, // Use more threads for faster processing
        debug: false,
      );

      // Create the TTS configuration optimized for speed
      final config = sherpa_onnx.OfflineTtsConfig(
        model: modelConfig,
        maxNumSenetences: 1, // Keep at 1 for minimal latency
        ruleFsts: '',
        ruleFars: '',
      );
      
      // Create the TTS instance
      _tts = sherpa_onnx.OfflineTts(config);
      
      _isInitialized = true;
      isInitialized.value = true;
      
      debugPrint('[TtsService] Successfully initialized TTS service with speed optimizations');
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

  /// Generate speech from text (optimized for low latency)
  Future<sherpa_onnx.GeneratedAudio> generateSpeech({
    required String text,
    double speed = 1.2, // Slightly faster default speed
    int speakerId = 0,
  }) async {
    if (!_isInitialized || _tts == null) {
      throw StateError('TTS service is not initialized. Call initialize() first.');
    }

    try {
      isProcessing.value = true;
      lastError.value = null;

      debugPrint('[TtsService] Generating speech for text: "$text" (speed: $speed, speaker: $speakerId)');

      // Generate audio using the persistent TTS instance
      final audio = _tts!.generate(
        text: text,
        sid: speakerId,
        speed: speed,
      );

      debugPrint('[TtsService] Generated audio: ${audio.samples.length} samples at ${audio.sampleRate}Hz');

      return audio;
    } catch (e) {
      final errorMsg = 'Failed to generate speech: $e';
      debugPrint('[TtsService] $errorMsg');
      lastError.value = errorMsg;
      rethrow;
    } finally {
      isProcessing.value = false;
    }
  }

  /// Generate speech and save to file (optimized for low latency)
  Future<String> generateSpeechToFile({
    required String text,
    required String outputPath,
    double speed = 1.2,
    int speakerId = 0,
  }) async {
    if (!_isInitialized) {
      throw StateError('TTS service is not initialized. Call initialize() first.');
    }

    try {
      isProcessing.value = true;
      lastError.value = null;
      
      // Aggressively optimize text for minimal latency
      final optimizedText = _optimizeTextForSpeed(text);
      
      debugPrint('[TtsService] Fast TTS generation for: "$optimizedText"');
      
      // Generate speech using the persistent instance (no isolate overhead)
      final audio = await generateSpeech(
        text: optimizedText,
        speed: speed,
        speakerId: speakerId,
      );

      // Save to file
      sherpa_onnx.writeWave(
        filename: outputPath,
        samples: audio.samples,
        sampleRate: audio.sampleRate,
      );

      debugPrint('[TtsService] Fast TTS generation completed and saved to $outputPath');
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

  /// Optimize text for maximum speed (aggressive optimization)
  String _optimizeTextForSpeed(String text) {
    // Remove excessive whitespace and clean up text
    String cleanText = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    
    // Remove complex punctuation that might slow down generation
    cleanText = cleanText.replaceAll(RegExp(r'[;:\[\](){}"*#]'), '');
    
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