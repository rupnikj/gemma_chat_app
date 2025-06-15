import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import './asr_model_config.dart';
import './asr_utils.dart';

class AsrResult {
  final String text;
  final bool isFinal;
  final int index;

  AsrResult({
    required this.text,
    required this.isFinal,
    required this.index,
  });
}

class AsrService {
  sherpa_onnx.OnlineRecognizer? _recognizer;
  sherpa_onnx.OnlineStream? _stream;
  late final AudioRecorder _audioRecorder;
  
  StreamSubscription<RecordState>? _recordSub;
  RecordState _recordState = RecordState.stop;
  
  final StreamController<AsrResult> _resultController = StreamController<AsrResult>.broadcast();
  final StreamController<RecordState> _stateController = StreamController<RecordState>.broadcast();
  
  bool _isInitialized = false;
  final int _sampleRate = 16000;
  int _index = 0;
  String _lastText = '';

  // Streams to listen to
  Stream<AsrResult> get resultStream => _resultController.stream;
  Stream<RecordState> get stateStream => _stateController.stream;
  
  // Current state
  RecordState get recordState => _recordState;
  bool get isInitialized => _isInitialized;

  AsrService() {
    _audioRecorder = AudioRecorder();
    _recordSub = _audioRecorder.onStateChanged().listen((recordState) {
      _updateRecordState(recordState);
    });
  }

  Future<void> initialize({int modelType = 0}) async {
    if (_isInitialized) return;

    try {
      sherpa_onnx.initBindings();
      _recognizer = await _createOnlineRecognizer(modelType: modelType);
      _stream = _recognizer?.createStream();
      _isInitialized = true;
    } catch (e) {
      debugPrint('Failed to initialize ASR service: $e');
      rethrow;
    }
  }

  Future<sherpa_onnx.OnlineRecognizer> _createOnlineRecognizer({int modelType = 0}) async {
    final modelConfig = await getOnlineModelConfig(type: modelType);
    final config = sherpa_onnx.OnlineRecognizerConfig(
      model: modelConfig,
      ruleFsts: '',
    );

    return sherpa_onnx.OnlineRecognizer(config);
  }

  Future<bool> startRecording() async {
    if (!_isInitialized) {
      throw StateError('ASR service not initialized. Call initialize() first.');
    }

    try {
      if (await _audioRecorder.hasPermission()) {
        const encoder = AudioEncoder.pcm16bits;

        if (!await _isEncoderSupported(encoder)) {
          return false;
        }

        const config = RecordConfig(
          encoder: encoder,
          sampleRate: 16000,
          numChannels: 1,
        );

        final stream = await _audioRecorder.startStream(config);

        stream.listen(
          (data) => _processAudioData(data),
          onDone: () {
            debugPrint('Audio stream stopped.');
          },
          onError: (error) {
            debugPrint('Audio stream error: $error');
          },
        );

        return true;
      }
    } catch (e) {
      debugPrint('Failed to start recording: $e');
    }
    return false;
  }

  void _processAudioData(List<int> data) {
    if (_stream == null || _recognizer == null) return;

    final samplesFloat32 = convertBytesToFloat32(Uint8List.fromList(data));

    _stream!.acceptWaveform(
      samples: samplesFloat32, 
      sampleRate: _sampleRate
    );
    
    while (_recognizer!.isReady(_stream!)) {
      _recognizer!.decode(_stream!);
    }
    
    final text = _recognizer!.getResult(_stream!).text;
    String textToDisplay = _lastText;
    
    if (text.isNotEmpty) {
      if (_lastText.isEmpty) {
        textToDisplay = '$_index: $text';
      } else {
        textToDisplay = '$_index: $text\n$_lastText';
      }
    }

    bool isFinal = false;
    if (_recognizer!.isEndpoint(_stream!)) {
      _recognizer!.reset(_stream!);
      if (text.isNotEmpty) {
        _lastText = textToDisplay;
        _index += 1;
        isFinal = true;
      }
    }
    
    _resultController.add(AsrResult(
      text: textToDisplay,
      isFinal: isFinal,
      index: _index,
    ));
  }

  Future<void> stopRecording() async {
    if (_stream != null && _recognizer != null) {
      _stream!.free();
      _stream = _recognizer!.createStream();
    }
    await _audioRecorder.stop();
  }

  Future<void> pauseRecording() async {
    await _audioRecorder.pause();
  }

  Future<void> resumeRecording() async {
    await _audioRecorder.resume();
  }

  void reset() {
    _lastText = '';
    _index = 0;
    if (_stream != null && _recognizer != null) {
      _stream!.free();
      _stream = _recognizer!.createStream();
    }
  }

  void _updateRecordState(RecordState recordState) {
    _recordState = recordState;
    _stateController.add(recordState);
  }

  Future<bool> _isEncoderSupported(AudioEncoder encoder) async {
    final isSupported = await _audioRecorder.isEncoderSupported(encoder);

    if (!isSupported) {
      debugPrint('${encoder.name} is not supported on this platform.');
      debugPrint('Supported encoders are:');

      for (final e in AudioEncoder.values) {
        if (await _audioRecorder.isEncoderSupported(e)) {
          debugPrint('- ${e.name}');
        }
      }
    }

    return isSupported;
  }

  void dispose() {
    _recordSub?.cancel();
    _audioRecorder.dispose();
    _stream?.free();
    _recognizer?.free();
    _resultController.close();
    _stateController.close();
  }
} 