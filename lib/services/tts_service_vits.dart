import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:archive/archive.dart';

class TtsService {
  static const String _modelAssetPath = 'assets/vits-piper-en_US-glados/en_US-glados.onnx';
  static const String _tokensAssetPath = 'assets/vits-piper-en_US-glados/tokens.txt';
  static const String _espeakDataArchivePath = 'assets/vits-piper-en_US-glados/espeak-ng-data.zip';

  sherpa_onnx.OfflineTts? _tts;
  bool _isInitialized = false;
  
  final ValueNotifier<bool> isInitialized = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isProcessing = ValueNotifier<bool>(false);
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  /// Initialize the TTS service by setting up sherpa-onnx bindings and loading the model
  Future<void> initialize() async {
    final totalStopwatch = Stopwatch()..start();
    final bindingStopwatch = Stopwatch();
    final assetStopwatch = Stopwatch();
    final modelLoadStopwatch = Stopwatch();

    try {
      lastError.value = null;
      
      debugPrint('[TtsService] 🚀 Starting TTS service initialization...');
      
      // Initialize sherpa-onnx bindings for Android
      bindingStopwatch.start();
      _initSherpaOnnxBindings();
      bindingStopwatch.stop();
      
      // Copy assets to local storage and get their paths
      assetStopwatch.start();
      final modelPaths = await _copyAssetsToLocal();
      assetStopwatch.stop();
      
      modelLoadStopwatch.start();
      final vits = sherpa_onnx.OfflineTtsVitsModelConfig(
        model: modelPaths['model']!,
        tokens: modelPaths['tokens']!,
        dataDir: modelPaths['dataDir']!,
        lengthScale: 1.0, // Slightly faster speed for lower latency
      );

      // Create the model configuration optimized for speed
      final modelConfig = sherpa_onnx.OfflineTtsModelConfig(
        vits: vits,
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
      modelLoadStopwatch.stop();
      
      totalStopwatch.stop();
      
      _isInitialized = true;
      isInitialized.value = true;
      
      debugPrint('[TtsService] 📊 INITIALIZATION PERFORMANCE METRICS:');
      debugPrint('[TtsService]   🔗 Sherpa-ONNX bindings: ${bindingStopwatch.elapsedMilliseconds}ms');
      debugPrint('[TtsService]   📦 Asset extraction: ${assetStopwatch.elapsedMilliseconds}ms');
      debugPrint('[TtsService]   🧠 Model loading: ${modelLoadStopwatch.elapsedMilliseconds}ms');
      debugPrint('[TtsService]   🕒 Total initialization: ${totalStopwatch.elapsedMilliseconds}ms');
      debugPrint('[TtsService] ✅ TTS service successfully initialized with speed optimizations');
    } catch (e) {
      totalStopwatch.stop();
      final errorMsg = 'Failed to initialize TTS service: $e';
      debugPrint('[TtsService] ❌ TTS initialization failed after ${totalStopwatch.elapsedMilliseconds}ms: $errorMsg');
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
        'tokens': _tokensAssetPath
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

      // Extract espeak-ng-data from compressed archive
      final dataDirPath = path.join(modelsDir.path, 'espeak-ng-data');
      await _extractEspeakDataArchive(dataDirPath);
      localPaths['dataDir'] = dataDirPath;

      return localPaths;
    } catch (e) {
      debugPrint('[TtsService] Failed to copy assets to local storage: $e');
      rethrow;
    }
  }

  /// Extract espeak-ng-data from compressed archive
  Future<void> _extractEspeakDataArchive(String extractPath) async {
    try {
      final extractDir = Directory(extractPath);
      
      // Check if already extracted by looking for key files
      if (await extractDir.exists()) {
        final phonDataFile = File(path.join(extractPath, 'phondata'));
        final voicesDir = Directory(path.join(extractPath, 'voices'));
        final langDir = Directory(path.join(extractPath, 'lang'));
        
        if (await phonDataFile.exists() && await voicesDir.exists() && await langDir.exists()) {
          debugPrint('[TtsService] espeak-ng-data already extracted at $extractPath');
          return;
        }
      }
      
      // Create extraction directory
      await extractDir.create(recursive: true);
      
      debugPrint('[TtsService] Extracting espeak-ng-data archive...');
      
      // Load the compressed archive from assets
      final byteData = await rootBundle.load(_espeakDataArchivePath);
      final bytes = byteData.buffer.asUint8List();
      
      debugPrint('[TtsService] Archive size: ${bytes.length} bytes');
      
      // Try to decompress the archive (try different formats)
      Archive archive;
      try {
        // First try as zip (most reliable with Flutter assets)
        archive = ZipDecoder().decodeBytes(bytes);
        debugPrint('[TtsService] Successfully decoded as zip');
      } catch (e) {
        debugPrint('[TtsService] Failed to decode as zip: $e');
        try {
          // Try as tar.gz
          archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
          debugPrint('[TtsService] Successfully decoded as tar.gz');
        } catch (e2) {
          debugPrint('[TtsService] Failed to decode as tar.gz: $e2');
          try {
            // Try as plain tar
            archive = TarDecoder().decodeBytes(bytes);
            debugPrint('[TtsService] Successfully decoded as plain tar');
          } catch (e3) {
            debugPrint('[TtsService] Failed all archive formats: zip($e), tar.gz($e2), tar($e3)');
            rethrow;
          }
        }
      }
      
      // Extract all files
      int extractedCount = 0;
      for (final file in archive) {
        // Strip the top-level 'espeak-ng-data/' directory from the path
        String relativePath = file.name;
        if (relativePath.startsWith('espeak-ng-data/')) {
          relativePath = relativePath.substring('espeak-ng-data/'.length);
        }
        
        // Skip if the path is empty (this would be the top-level directory itself)
        if (relativePath.isEmpty) {
          continue;
        }
        
        final filePath = path.join(extractPath, relativePath);
        
        if (file.isFile) {
          final localFile = File(filePath);
          await localFile.parent.create(recursive: true);
          await localFile.writeAsBytes(file.content);
          extractedCount++;
        } else {
          // Create directory
          final dir = Directory(filePath);
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
        }
      }
      
      debugPrint('[TtsService] Successfully extracted $extractedCount files from espeak-ng-data archive to $extractPath');
      
    } catch (e) {
      debugPrint('[TtsService] Failed to extract espeak-ng-data archive: $e');
      rethrow;
    }
  }

  /// Generate speech from text (optimized for low latency)
  Future<sherpa_onnx.GeneratedAudio> generateSpeech({
    required String text,
    double speed = 1.0, // Slightly faster default speed
    int speakerId = 0,
  }) async {
    if (!_isInitialized || _tts == null) {
      throw StateError('TTS service is not initialized. Call initialize() first.');
    }

    final totalStopwatch = Stopwatch()..start();
    final ttsStopwatch = Stopwatch();

    try {
      isProcessing.value = true;
      lastError.value = null;

      debugPrint('[TtsService] 🎯 Starting TTS generation for text: "$text" (speed: $speed, speaker: $speakerId)');

      // Measure TTS generation time
      ttsStopwatch.start();
      final audio = _tts!.generate(
        text: text,
        sid: speakerId,
        speed: speed,
      );
      ttsStopwatch.stop();

      totalStopwatch.stop();

      // Calculate performance metrics
      final textLength = text.length;
      final audioLengthMs = (audio.samples.length / audio.sampleRate * 1000).round();
      final ttsTimeMs = ttsStopwatch.elapsedMilliseconds;
      final totalTimeMs = totalStopwatch.elapsedMilliseconds;
      final realTimeRatio = audioLengthMs > 0 ? (ttsTimeMs / audioLengthMs) : 0;

      debugPrint('[TtsService] 📊 TTS PERFORMANCE METRICS:');
      debugPrint('[TtsService]   📝 Text length: $textLength chars');
      debugPrint('[TtsService]   🎵 Audio length: ${audioLengthMs}ms (${audio.samples.length} samples @ ${audio.sampleRate}Hz)');
      debugPrint('[TtsService]   ⚡ TTS generation: ${ttsTimeMs}ms');
      debugPrint('[TtsService]   🕒 Total time: ${totalTimeMs}ms');
      debugPrint('[TtsService]   🏃 Real-time ratio: ${realTimeRatio.toStringAsFixed(2)}x ${realTimeRatio < 1.0 ? '(FASTER than real-time)' : '(SLOWER than real-time)'}');
      debugPrint('[TtsService]   📈 Generation speed: ${(textLength / ttsTimeMs * 1000).toStringAsFixed(1)} chars/sec');

      return audio;
    } catch (e) {
      totalStopwatch.stop();
      final errorMsg = 'Failed to generate speech: $e';
      debugPrint('[TtsService] ❌ TTS generation failed after ${totalStopwatch.elapsedMilliseconds}ms: $errorMsg');
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

    final totalStopwatch = Stopwatch()..start();
    final textOptStopwatch = Stopwatch();
    final fileWriteStopwatch = Stopwatch();

    try {
      isProcessing.value = true;
      lastError.value = null;
      
      debugPrint('[TtsService] 🎯 Starting TTS-to-file pipeline for: "$text"');
      
      // Measure text optimization time
      textOptStopwatch.start();
      final optimizedText = _optimizeTextForSpeed(text);
      textOptStopwatch.stop();
      
      debugPrint('[TtsService] 🔧 Text optimization: ${textOptStopwatch.elapsedMilliseconds}ms ("$text" → "$optimizedText")');
      
      // Generate speech using the persistent instance (this has its own profiling)
      final audio = await generateSpeech(
        text: optimizedText,
        speed: speed,
        speakerId: speakerId,
      );

      // Measure file writing time
      debugPrint('[TtsService] 💾 Writing ${audio.samples.length} samples to file...');
      fileWriteStopwatch.start();
      sherpa_onnx.writeWave(
        filename: outputPath,
        samples: audio.samples,
        sampleRate: audio.sampleRate,
      );
      fileWriteStopwatch.stop();

      totalStopwatch.stop();

      // Calculate file size
      final outputFile = File(outputPath);
      final fileSizeKB = (await outputFile.length()) / 1024;
      final audioLengthMs = (audio.samples.length / audio.sampleRate * 1000).round();

      debugPrint('[TtsService] 📊 FILE GENERATION PIPELINE METRICS:');
      debugPrint('[TtsService]   🔧 Text optimization: ${textOptStopwatch.elapsedMilliseconds}ms');
      debugPrint('[TtsService]   💾 File write (WAV): ${fileWriteStopwatch.elapsedMilliseconds}ms');
      debugPrint('[TtsService]   📁 Output file size: ${fileSizeKB.toStringAsFixed(1)} KB');
      debugPrint('[TtsService]   🕒 Total pipeline time: ${totalStopwatch.elapsedMilliseconds}ms');
      debugPrint('[TtsService]   💿 Write speed: ${(fileSizeKB / fileWriteStopwatch.elapsedMilliseconds * 1000).toStringAsFixed(1)} KB/sec');
      debugPrint('[TtsService] ✅ TTS-to-file completed: $outputPath');

      return outputPath;
    } catch (e) {
      totalStopwatch.stop();
      final errorMsg = 'Failed to generate speech to file: $e';
      debugPrint('[TtsService] ❌ TTS-to-file failed after ${totalStopwatch.elapsedMilliseconds}ms: $errorMsg');
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
    // This is a placeholder - you might want to make this configurable
    return List.generate(1, (index) => index); // Speakers 0-9
  }

  /// Check if the service is ready to use
  bool get isReady => _isInitialized;

  /// Get performance summary for monitoring
  Map<String, dynamic> getPerformanceStats() {
    return {
      'isInitialized': _isInitialized,
      'isProcessing': isProcessing.value,
      'lastError': lastError.value,
      'availableSpeakers': getAvailableSpeakers().length,
      'modelConfig': {
        'numThreads': 4,
        'lengthScale': 0.8,
        'maxNumSentences': 1,
      },
      'optimizations': {
        'speedOptimized': true,
        'persistentInstance': true,
        'preloadedAssets': true,
      }
    };
  }

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