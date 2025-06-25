import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'tts_service_vits.dart';

  /// A streaming TTS service that processes and plays sentences in real-time
/// as they arrive from the LLM, enabling seamless voice synthesis during text generation
class StreamingTtsService {
  final TtsService _ttsService;
  final AudioPlayer _audioPlayer;
  
  // Sentence processing pipeline
  final Queue<String> _sentenceQueue = Queue<String>();
  final Queue<String> _audioFileQueue = Queue<String>();
  final Set<String> _tempFiles = <String>{};
  
  // State management
  bool _isProcessing = false;
  bool _isPlaying = false;
  bool _shouldStop = false;
  String _partialText = '';
  bool _isTextStreamComplete = false; // Track when text stream is done
  
  // Performance tracking
  int _sentencesProcessed = 0;
  int _totalProcessingTimeMs = 0;
  late Stopwatch _streamingStopwatch;
  
  // Notifiers for UI
  final ValueNotifier<bool> isStreaming = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isGeneratingAudio = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isPlayingAudio = ValueNotifier<bool>(false);
  final ValueNotifier<String?> currentSentence = ValueNotifier<String?>(null);
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);
  final ValueNotifier<String?> activeMessageId = ValueNotifier<String?>(null); // Track which message is being processed

  StreamingTtsService(this._ttsService, this._audioPlayer);

  /// Initialize the streaming TTS service
  Future<void> initialize() async {
    if (!_ttsService.isReady) {
      throw StateError('Base TTS service must be initialized first');
    }
    
    // Audio player completion is now handled in the pipeline directly
    
    debugPrint('[StreamingTTS] ✅ Streaming TTS service initialized');
  }

  /// Start streaming TTS from a text stream (e.g., LLM token stream)
  /// Each token/chunk of text is processed to detect sentence boundaries
  Future<void> startStreaming(
    Stream<String> textStream, {
    double speed = 1.2,
    int speakerId = 0,
    String? messageId, // Unique identifier for the message being processed
  }) async {
    if (!_ttsService.isReady) {
      throw StateError('TTS service is not ready');
    }

    if (_isProcessing) {
      debugPrint('[StreamingTTS] ⚠️ Already processing, stopping current stream first');
      await stopStreaming();
      // Add a small delay to ensure cleanup is complete
      await Future.delayed(const Duration(milliseconds: 100));
    }

    // Reset state for new streaming session
    _reset();
    _streamingStopwatch = Stopwatch()..start();
    
    isStreaming.value = true;
    activeMessageId.value = messageId; // Set the active message ID
    lastError.value = null;
    
    debugPrint('[StreamingTTS] 🚀 Starting streaming TTS (speed: $speed, speaker: $speakerId, messageId: $messageId)');
    debugPrint('[StreamingTTS] 🔍 Initial state: partialText="$_partialText", processing=$_isProcessing, shouldStop=$_shouldStop');

    try {
      // Start concurrent processing pipelines
      _isProcessing = true;
      
      // Pipeline 1: Process incoming text tokens and detect sentences
      final textProcessingFuture = _processTextStream(textStream);
      
      // Pipeline 2: Generate TTS for queued sentences
      final ttsProcessingFuture = _processTtsQueue(speed: speed, speakerId: speakerId);
      
      // Pipeline 3: Play generated audio files
      final audioPlaybackFuture = _processAudioQueue();
      
      // Wait for all pipelines to complete
      await Future.wait([
        textProcessingFuture,
        ttsProcessingFuture,
        audioPlaybackFuture,
      ]);
      
      _streamingStopwatch.stop();
      
      // Ensure all generation states are properly reset when pipelines complete naturally
      isGeneratingAudio.value = false;
      currentSentence.value = null;
      
      debugPrint('[StreamingTTS] 📊 STREAMING SESSION COMPLETED:');
      debugPrint('[StreamingTTS]   🔢 Sentences processed: $_sentencesProcessed');
      debugPrint('[StreamingTTS]   ⏱️ Total session time: ${_streamingStopwatch.elapsedMilliseconds}ms');
      debugPrint('[StreamingTTS]   ⚡ Avg processing per sentence: ${_sentencesProcessed > 0 ? (_totalProcessingTimeMs / _sentencesProcessed).round() : 0}ms');
      
    } catch (e) {
      debugPrint('[StreamingTTS] ❌ Error during streaming: $e');
      lastError.value = e.toString();
      rethrow;
    } finally {
      await _cleanup();
      isStreaming.value = false;
      _isProcessing = false;
      debugPrint('[StreamingTTS] 🔍 Final cleanup: partialText="$_partialText", processing=$_isProcessing, shouldStop=$_shouldStop');
    }
  }

  /// Stop the current streaming session
  Future<void> stopStreaming() async {
    debugPrint('[StreamingTTS] 🛑 Stopping streaming session...');
    debugPrint('[StreamingTTS] 🛑 Before stop: sentenceQueue=${_sentenceQueue.length}, audioQueue=${_audioFileQueue.length}, partialText="$_partialText"');
    
    _shouldStop = true;
    isStreaming.value = false;
    
    // Stop audio playback
    try {
      await _audioPlayer.stop();
    } catch (e) {
      debugPrint('[StreamingTTS] Warning: Error stopping audio player: $e');
    }
    
    // Wait a bit for pipelines to stop gracefully
    await Future.delayed(const Duration(milliseconds: 100));
    
    // Clean up resources
    await _cleanup();
    
    debugPrint('[StreamingTTS] ✅ Streaming session stopped');
  }

  /// Process the incoming text stream and detect sentence boundaries
  Future<void> _processTextStream(Stream<String> textStream) async {
    debugPrint('[StreamingTTS] 📝 Starting text processing pipeline...');
    
    try {
      await for (final token in textStream) {
        if (_shouldStop) break;
        
        _partialText += token;
        
        // Check for sentence boundaries
        final sentences = _extractCompleteSentences(_partialText);
        
        for (final sentence in sentences) {
          if (_shouldStop) break;
          
          final cleanSentence = sentence.trim();
          if (cleanSentence.isNotEmpty) {
            _sentenceQueue.add(cleanSentence);
            debugPrint('[StreamingTTS] 📝 Queued sentence: "${cleanSentence.length > 50 ? '${cleanSentence.substring(0, 50)}...' : cleanSentence}"');
          }
        }
      }
      
      // Process any remaining partial text as a final sentence
      if (!_shouldStop && _partialText.trim().isNotEmpty) {
        final finalSentence = _partialText.trim();
        _sentenceQueue.add(finalSentence);
        debugPrint('[StreamingTTS] 📝 Queued final sentence: "${finalSentence.length > 50 ? '${finalSentence.substring(0, 50)}...' : finalSentence}"');
        _partialText = ''; // Clear after processing final sentence
      }
      
    } catch (e) {
      debugPrint('[StreamingTTS] ❌ Error in text processing pipeline: $e');
      rethrow;
    }
    
    debugPrint('[StreamingTTS] ✅ Text processing pipeline completed');
    _isTextStreamComplete = true; // Mark text stream as complete
  }

  /// Process the TTS queue - generate audio for sentences
  Future<void> _processTtsQueue({required double speed, required int speakerId}) async {
    debugPrint('[StreamingTTS] 🎯 Starting TTS processing pipeline...');
    
    try {
      while (!_shouldStop) {
        // Wait for sentences to be available or processing to complete
        if (_sentenceQueue.isEmpty) {
          await Future.delayed(const Duration(milliseconds: 50));
          continue;
        }
        
        final sentence = _sentenceQueue.removeFirst();
        currentSentence.value = sentence;
        isGeneratingAudio.value = true;
        
        final ttsStopwatch = Stopwatch()..start();
        
        try {
          // Generate unique filename for this audio segment
          final tempDir = await getTemporaryDirectory();
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          final audioPath = path.join(tempDir.path, 'streaming_tts_${timestamp}_$_sentencesProcessed.wav');
          
          debugPrint('[StreamingTTS] 🎵 Generating TTS for sentence ${_sentencesProcessed + 1}: "${sentence.length > 30 ? '${sentence.substring(0, 30)}...' : sentence}"');
          
          // Generate speech with optimized settings for streaming
          await _ttsService.generateSpeechToFile(
            text: sentence,
            outputPath: audioPath,
            speed: speed,
            speakerId: speakerId,
          );
          
          ttsStopwatch.stop();
          
          // Add to audio queue and track the temp file
          _audioFileQueue.add(audioPath);
          _tempFiles.add(audioPath);
          _sentencesProcessed++;
          _totalProcessingTimeMs += ttsStopwatch.elapsedMilliseconds;
          
          debugPrint('[StreamingTTS] ✅ TTS generated in ${ttsStopwatch.elapsedMilliseconds}ms, queued: $audioPath');
          debugPrint('[StreamingTTS] 🔍 Audio queue now has ${_audioFileQueue.length} files');
          
        } catch (e) {
          debugPrint('[StreamingTTS] ❌ Error generating TTS for sentence: $e');
          // Continue processing other sentences even if one fails
          continue;
        } finally {
          isGeneratingAudio.value = false;
          currentSentence.value = null;
        }
      }
    } catch (e) {
      debugPrint('[StreamingTTS] ❌ Error in TTS processing pipeline: $e');
      rethrow;
    } finally {
      // Ensure isGeneratingAudio is reset when pipeline completes
      isGeneratingAudio.value = false;
      currentSentence.value = null;
    }
    
    debugPrint('[StreamingTTS] ✅ TTS processing pipeline completed');
  }

  /// Process the audio queue - play generated audio files
  Future<void> _processAudioQueue() async {
    debugPrint('[StreamingTTS] 🔊 Starting audio playback pipeline...');
    
    // Wait for either the first audio file to be available OR text processing to complete
    bool firstAudioReceived = false;
    
    while (!_shouldStop) {
      // Check if we have audio files to play
      if (_audioFileQueue.isNotEmpty) {
        firstAudioReceived = true;
        final audioFile = _audioFileQueue.removeFirst();
        debugPrint('[StreamingTTS] 🎵 Playing audio file: ${audioFile.split('/').last}');
        
        try {
          // Use the shared audio player with completer for reliable completion detection
          final completer = Completer<void>();
          late StreamSubscription subscription;
          
          subscription = _audioPlayer.onPlayerComplete.listen((event) {
            if (!completer.isCompleted) {
              completer.complete();
              subscription.cancel(); // Cancel subscription to avoid memory leaks
            }
          });
          
          await _audioPlayer.play(DeviceFileSource(audioFile));
          
          // Wait for completion with timeout protection
          await completer.future.timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              debugPrint('[StreamingTTS] ⚠️ Audio playback timeout, continuing...');
              subscription.cancel(); // Cancel on timeout
            },
          );
          
          debugPrint('[StreamingTTS] ✅ Audio file completed: ${audioFile.split('/').last}');
          
          // Clean up the temporary file
          try {
            await File(audioFile).delete();
            debugPrint('[StreamingTTS] 🗑️ Cleaned up audio file: ${audioFile.split('/').last}');
          } catch (e) {
            debugPrint('[StreamingTTS] ⚠️ Failed to delete audio file: $e');
          }
          
        } catch (e) {
          debugPrint('[StreamingTTS] ❌ Audio playback error: $e');
        }
        
        continue; // Continue to next iteration to check for more files
      }
      
      // No audio files available - check if we should continue waiting
      final shouldWaitForMore = !firstAudioReceived || // Haven't received first audio yet
                               isGeneratingAudio.value ||      // TTS is still generating
                               _sentenceQueue.isNotEmpty ||    // More sentences waiting
                               !_isTextStreamComplete;         // Text stream still active
      
      debugPrint('[StreamingTTS] 🔍 Pipeline decision: firstAudioReceived=$firstAudioReceived, isGeneratingAudio=${isGeneratingAudio.value}, sentenceQueue=${_sentenceQueue.length}, audioQueue=${_audioFileQueue.length}, textStreamComplete=$_isTextStreamComplete, shouldStop=$_shouldStop');
       
      if (!shouldWaitForMore) {
        debugPrint('[StreamingTTS] 🔍 Audio pipeline check: queue=${_audioFileQueue.length}, sentences=${_sentenceQueue.length}, generating=${isGeneratingAudio.value}, textComplete=$_isTextStreamComplete, shouldStop=$_shouldStop');
        debugPrint('[StreamingTTS] 🔍 Pipeline might be done, doing final check...');
        
        // Final check - wait a bit in case there are pending operations
        await Future.delayed(const Duration(milliseconds: 500));
        
        if (_audioFileQueue.isEmpty && 
            _sentenceQueue.isEmpty && 
            !isGeneratingAudio.value && 
            _isTextStreamComplete &&    // Only exit when text stream is complete
            !_shouldStop) {
          debugPrint('[StreamingTTS] 🔍 Pipeline confirmed done, exiting audio playback loop');
          break;
        } else {
          debugPrint('[StreamingTTS] 🔍 Pipeline still has work: queue=${_audioFileQueue.length}, sentences=${_sentenceQueue.length}, generating=${isGeneratingAudio.value}, textComplete=$_isTextStreamComplete');
        }
      }
      
      // Wait before checking again
      await Future.delayed(const Duration(milliseconds: 100));
    }
    
    debugPrint('[StreamingTTS] ✅ Audio playback pipeline completed');
  }

  /// Extract complete sentences from text, keeping partial sentences for next iteration
  List<String> _extractCompleteSentences(String text) {
    final sentences = <String>[];    
    
    // Split on common sentence endings, but keep the delimiter
    final parts = text.split(RegExp(r'(?<=[.!?])\s+'));
    
    for (int i = 0; i < parts.length - 1; i++) {
      final sentence = parts[i].trim();
      if (sentence.isNotEmpty) {
        sentences.add(sentence);
      }
    }
    
    // Update partial text with the last part (might be incomplete sentence)
    if (parts.isNotEmpty) {
      final lastPart = parts.last.trim();
      // If the last part ends with sentence punctuation, it's complete
      if (lastPart.endsWith('.') || lastPart.endsWith('!') || lastPart.endsWith('?')) {
        if (lastPart.isNotEmpty) {
          sentences.add(lastPart);
        }
        _partialText = '';
      } else {
        _partialText = lastPart;
      }
    }
    
    return sentences;
  }

  /// Reset state for new streaming session
  void _reset() {
    debugPrint('[StreamingTTS] 🔄 Resetting streaming state...');
    
    _sentenceQueue.clear();
    _audioFileQueue.clear();
    _partialText = '';
    _shouldStop = false;
    _isPlaying = false;
    _isTextStreamComplete = false; // Reset text stream completion flag
    _sentencesProcessed = 0;
    _totalProcessingTimeMs = 0;
    
    isGeneratingAudio.value = false;
    isPlayingAudio.value = false;
    currentSentence.value = null;
    lastError.value = null;
    activeMessageId.value = null; // Clear active message ID
    
    debugPrint('[StreamingTTS] ✅ State reset complete');
  }

  /// Clean up resources and temporary files
  Future<void> _cleanup() async {
    debugPrint('[StreamingTTS] 🧹 Cleaning up streaming session...');
    
    // Clear queues
    _sentenceQueue.clear();
    _audioFileQueue.clear();
    
    // Delete any remaining temporary files
    for (final filePath in _tempFiles) {
      try {
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        debugPrint('[StreamingTTS] Warning: Could not delete temp file $filePath: $e');
      }
    }
    _tempFiles.clear();
    
    // Reset state - ensure _partialText is completely cleared
    _reset();
    
    debugPrint('[StreamingTTS] ✅ Cleanup completed');
  }

  /// Get current streaming statistics
  Map<String, dynamic> getStreamingStats() {
    return {
      'isStreaming': isStreaming.value,
      'isGeneratingAudio': isGeneratingAudio.value,
      'isPlayingAudio': isPlayingAudio.value,
      'sentencesProcessed': _sentencesProcessed,
      'sentencesInQueue': _sentenceQueue.length,
      'audioFilesInQueue': _audioFileQueue.length,
      'currentSentence': currentSentence.value,
      'averageProcessingTime': _sentencesProcessed > 0 ? (_totalProcessingTimeMs / _sentencesProcessed).round() : 0,
      'totalSessionTime': _streamingStopwatch.isRunning ? _streamingStopwatch.elapsedMilliseconds : 0,
    };
  }

  /// Check if the service is ready for streaming
  bool get isReady => _ttsService.isReady;

  /// Dispose of resources
  void dispose() {
    debugPrint('[StreamingTTS] 🗑️ Disposing streaming TTS service...');
    
    stopStreaming();
    // Note: We don't dispose the audio player since it's shared
    
    // Dispose notifiers
    isStreaming.dispose();
    isGeneratingAudio.dispose();
    isPlayingAudio.dispose();
    currentSentence.dispose();
    lastError.dispose();
    activeMessageId.dispose(); // Dispose active message ID notifier
    
    debugPrint('[StreamingTTS] ✅ Streaming TTS service disposed');
  }
} 