import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

class AsrService {
  static const String _encoderAssetPath = 'assets/sherpa-onnx-whisper-tiny/tiny-encoder.int8.onnx';
  static const String _decoderAssetPath = 'assets/sherpa-onnx-whisper-tiny/tiny-decoder.int8.onnx';
  static const String _tokensAssetPath = 'assets/sherpa-onnx-whisper-tiny/tiny-tokens.txt';

  sherpa_onnx.OfflineRecognizer? _recognizer;
  bool _isInitialized = false;
  
  final ValueNotifier<bool> isInitialized = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isProcessing = ValueNotifier<bool>(false);
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  /// Initialize the ASR service by setting up sherpa-onnx bindings and loading the model
  Future<void> initialize() async {
    try {
      lastError.value = null;
      
      // Initialize sherpa-onnx bindings for Android
      _initSherpaOnnxBindings();
      
      // Copy assets to local storage and get their paths
      final modelPaths = await _copyAssetsToLocal();
      
      // Create the whisper model configuration
      final whisper = sherpa_onnx.OfflineWhisperModelConfig(
        encoder: modelPaths['encoder']!,
        decoder: modelPaths['decoder']!,
      );

      // Create the model configuration
      final modelConfig = sherpa_onnx.OfflineModelConfig(
        whisper: whisper,
        tokens: modelPaths['tokens']!,
        modelType: 'whisper',
        debug: false,
        numThreads: 1,
      );

      // Create the recognizer configuration
      final config = sherpa_onnx.OfflineRecognizerConfig(model: modelConfig);
      
      // Create the recognizer
      _recognizer = sherpa_onnx.OfflineRecognizer(config);
      
      _isInitialized = true;
      isInitialized.value = true;
      
      debugPrint('[AsrService] Successfully initialized ASR service');
    } catch (e) {
      final errorMsg = 'Failed to initialize ASR service: $e';
      debugPrint('[AsrService] $errorMsg');
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
      debugPrint('[AsrService] Sherpa-ONNX bindings initialized');
    } catch (e) {
      debugPrint('[AsrService] Failed to initialize sherpa-onnx bindings: $e');
      rethrow;
    }
  }

  /// Copy model assets from bundle to local storage
  Future<Map<String, String>> _copyAssetsToLocal() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final modelsDir = Directory(path.join(appDir.path, 'sherpa_onnx_models'));
      
      if (!await modelsDir.exists()) {
        await modelsDir.create(recursive: true);
      }

      final Map<String, String> assetPaths = {
        'encoder': _encoderAssetPath,
        'decoder': _decoderAssetPath,
        'tokens': _tokensAssetPath,
      };

      final Map<String, String> localPaths = {};

      for (final entry in assetPaths.entries) {
        final assetKey = entry.key;
        final assetPath = entry.value;
        final fileName = path.basename(assetPath);
        final localPath = path.join(modelsDir.path, fileName);
        
        // Check if file already exists
        final localFile = File(localPath);
        if (!await localFile.exists()) {
          debugPrint('[AsrService] Copying $assetPath to $localPath');
          final byteData = await rootBundle.load(assetPath);
          final bytes = byteData.buffer.asUint8List();
          await localFile.writeAsBytes(bytes);
        } else {
          debugPrint('[AsrService] File $localPath already exists, skipping copy');
        }
        
        localPaths[assetKey] = localPath;
      }

      return localPaths;
    } catch (e) {
      debugPrint('[AsrService] Failed to copy assets to local storage: $e');
      rethrow;
    }
  }

  /// Transcribe audio from a WAV file
  Future<String> transcribeFromFile(String wavFilePath) async {
    if (!_isInitialized || _recognizer == null) {
      throw StateError('ASR service is not initialized. Call initialize() first.');
    }

    try {
      isProcessing.value = true;
      lastError.value = null;

      debugPrint('[AsrService] Starting transcription of file: $wavFilePath');

      // Read the wave file
      final waveData = sherpa_onnx.readWave(wavFilePath);
      
      // Create a stream for processing
      final stream = _recognizer!.createStream();

      // Accept the waveform data
      stream.acceptWaveform(
        samples: waveData.samples,
        sampleRate: waveData.sampleRate,
      );

      // Decode the audio
      _recognizer!.decode(stream);

      // Get the result
      final result = _recognizer!.getResult(stream);
      
      // Clean up the stream
      stream.free();

      final transcription = result.text.trim();
      debugPrint('[AsrService] Transcription result: "$transcription"');

      return transcription;
    } catch (e) {
      final errorMsg = 'Failed to transcribe audio: $e';
      debugPrint('[AsrService] $errorMsg');
      lastError.value = errorMsg;
      rethrow;
    } finally {
      isProcessing.value = false;
    }
  }

  /// Transcribe audio from raw samples
  Future<String> transcribeFromSamples(Float32List samples, int sampleRate) async {
    if (!_isInitialized || _recognizer == null) {
      throw StateError('ASR service is not initialized. Call initialize() first.');
    }

    try {
      isProcessing.value = true;
      lastError.value = null;

      debugPrint('[AsrService] Starting transcription from samples (${samples.length} samples, ${sampleRate}Hz)');

      // Create a stream for processing
      final stream = _recognizer!.createStream();

      // Accept the waveform data
      stream.acceptWaveform(samples: samples, sampleRate: sampleRate);

      // Decode the audio
      _recognizer!.decode(stream);

      // Get the result
      final result = _recognizer!.getResult(stream);
      
      // Clean up the stream
      stream.free();

      final transcription = result.text.trim();
      debugPrint('[AsrService] Transcription result: "$transcription"');

      return transcription;
    } catch (e) {
      final errorMsg = 'Failed to transcribe audio samples: $e';
      debugPrint('[AsrService] $errorMsg');
      lastError.value = errorMsg;
      rethrow;
    } finally {
      isProcessing.value = false;
    }
  }

  /// Check if the service is ready to process audio
  bool get isReady => _isInitialized && _recognizer != null;

  /// Dispose of resources
  void dispose() {
    try {
      _recognizer?.free();
      _recognizer = null;
      _isInitialized = false;
      isInitialized.value = false;
      isProcessing.value = false;
      lastError.value = null;
      
      debugPrint('[AsrService] ASR service disposed');
    } catch (e) {
      debugPrint('[AsrService] Error during disposal: $e');
    }
  }
} 