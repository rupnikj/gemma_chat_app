import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:io' show Platform, File;
import 'dart:async';
import 'package:provider/provider.dart';
import 'package:gemma_chat_app/services/chat_service.dart';
import 'package:gemma_chat_app/services/asr_service.dart';
import 'package:gemma_chat_app/services/tts_service_vits.dart';
import 'package:gemma_chat_app/services/streaming_tts_service.dart';
import 'package:gemma_chat_app/screens/settings_screen.dart';
import 'package:flutter_gemma/flutter_gemma.dart'; // For Message class
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:audioplayers/audioplayers.dart';

class Message {
  final String text;
  final bool isUser;
  final String id; // Unique identifier for each message

  Message({
    required this.text, 
    required this.isUser,
    String? id,
  }) : id = id ?? DateTime.now().millisecondsSinceEpoch.toString();
}

void main() {
  // Ensure Flutter bindings are initialized
  WidgetsFlutterBinding.ensureInitialized();

  // Create an instance of ChatService
  final chatService = ChatService();

  // It's good practice to initialize the service early,
  // especially if it involves async operations like reading SharedPreferences.
  // We can await this here or let the UI handle loading states.
  // For simplicity, we'll let the UI handle it via a FutureBuilder or ValueListenableBuilder.
  // chatService.initialize(); // We will call this from ChatScreen initState

  runApp(Provider(create: (_) => chatService, child: const MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gemma Chat App',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.dark, // Dark theme
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();

  List<Message> _messages = [];
  bool _isSending = false;
  bool _isModelInitializing = true; // To show loading initially
  bool _shouldAutoScroll = true; // Track if auto-scroll is enabled
  bool _isProgrammaticallyScrolling = false; // Track programmatic scrolling
  double _lastScrollPosition = 0.0; // Track last scroll position

  late ChatService _chatService;
  late AsrService _asrService;
  late TtsService _ttsService;
  late StreamingTtsService _streamingTtsService;
  
  // Recording state
  bool _isRecording = false;
  bool _isTranscribing = false;
  String? _recordingPath;

  @override
  void initState() {
    super.initState();
    _chatService = Provider.of<ChatService>(context, listen: false);
    _asrService = AsrService();
    _ttsService = TtsService();
    _streamingTtsService = StreamingTtsService(_ttsService, _audioPlayer);

    // Listen to model readiness and path changes to rebuild UI
    _chatService.isModelReady.addListener(_onModelStateChanged);
    _chatService.currentModelPath.addListener(_onModelStateChanged);

    // Add scroll listener to detect manual scrolling
    _scrollController.addListener(_onScroll);

    _initializeChatService();
    _initializeAsrService();
    _initializeTtsService();
    _initializeStreamingTtsService();
  }

  // Handle scroll events to detect manual scrolling
  void _onScroll() {
    if (!_scrollController.hasClients || _isProgrammaticallyScrolling) return;

    final currentScroll = _scrollController.position.pixels;
    final maxScroll = _scrollController.position.maxScrollExtent;

    // Check if user is scrolling up (manual scroll)
    final isScrollingUp = currentScroll < _lastScrollPosition;

    // Very small threshold - essentially at the very bottom
    const threshold = 5.0;
    final isAtBottom = (maxScroll - currentScroll) <= threshold;

    if (isScrollingUp && _shouldAutoScroll) {
      // User is scrolling up - disable auto-scroll immediately
      setState(() {
        _shouldAutoScroll = false;
      });
      print("[ChatScreen] Upward scroll detected - disabling auto-scroll");
    } else if (isAtBottom && !_shouldAutoScroll) {
      // User scrolled back to bottom - re-enable auto-scroll
      setState(() {
        _shouldAutoScroll = true;
      });
      print("[ChatScreen] Scrolled to bottom - enabling auto-scroll");
    }

    _lastScrollPosition = currentScroll;
  }

  Future<void> _initializeChatService() async {
    setState(() {
      _isModelInitializing = true;
      _messages =
          []; // Clear messages during re-initialization - already a modifiable list
    });
    try {
      await _chatService.initialize(); // Loads saved model if any
      // Create a new modifiable list from the chat history
      _messages = List<Message>.from(_chatService.getChatHistory());
    } catch (e) {
      print("Error initializing ChatService: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error initializing: ${e.toString()}'),
            behavior: SnackBarBehavior.fixed,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isModelInitializing = false;
        });
      }
    }
  }

  Future<void> _initializeAsrService() async {
    try {
      await _asrService.initialize();
      print("ASR Service initialized successfully");
    } catch (e) {
      print("Error initializing ASR Service: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ASR initialization failed: ${e.toString()}'),
            behavior: SnackBarBehavior.fixed,
          ),
        );
      }
    }
  }

  Future<void> _initializeTtsService() async {
    try {
      await _ttsService.initialize();
      print("TTS Service initialized successfully");
    } catch (e) {
      print("Error initializing TTS Service: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('TTS initialization failed: ${e.toString()}'),
            behavior: SnackBarBehavior.fixed,
          ),
        );
      }
    }
  }

  Future<void> _initializeStreamingTtsService() async {
    try {
      await _streamingTtsService.initialize();
      print("Streaming TTS Service initialized successfully");
    } catch (e) {
      print("Error initializing Streaming TTS Service: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Streaming TTS initialization failed: ${e.toString()}'),
            behavior: SnackBarBehavior.fixed,
          ),
        );
      }
    }
  }

  void _onModelStateChanged() {
    if (mounted) {
      setState(() {
        // Just rebuild to reflect new state from ValueNotifiers
        if (_chatService.isModelReady.value) {
          // Always create a new modifiable list from the chat history
          final history = _chatService.getChatHistory();
          _messages = List<Message>.from(history);
        } else {
          // If model is not ready, clear messages
          _messages = [];
        }
      });
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.removeListener(_onScroll); // Remove scroll listener
    _scrollController.dispose();
    _chatService.isModelReady.removeListener(_onModelStateChanged);
    _chatService.currentModelPath.removeListener(_onModelStateChanged);
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _asrService.dispose();
    _ttsService.dispose();
    _streamingTtsService.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients && _shouldAutoScroll) {
      _isProgrammaticallyScrolling = true; // Flag to ignore scroll events
      _scrollController
          .animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          )
          .then((_) {
            // Re-enable scroll detection after animation completes
            _isProgrammaticallyScrolling = false;
          });
    }
  }

  // Alternative: Use jumpTo for instant scrolling during token streaming
  void _jumpToBottom() {
    if (_scrollController.hasClients && _shouldAutoScroll) {
      _isProgrammaticallyScrolling = true;
      final targetPosition = _scrollController.position.maxScrollExtent;
      _scrollController.jumpTo(targetPosition);
      _lastScrollPosition = targetPosition; // Update our tracking

      // Use a very short delay
      Future.delayed(const Duration(milliseconds: 5), () {
        _isProgrammaticallyScrolling = false;
      });
    }
  }

  Future<void> _handleSendMessage() async {
    final text = _textController.text.trim();
    print("[ChatScreen] _handleSendMessage: Called. Text: '$text'");

    if (text.isEmpty) {
      print("[ChatScreen] _handleSendMessage: Text is empty. Exiting.");
      return;
    }
    if (!_chatService.isModelReady.value) {
      print("[ChatScreen] _handleSendMessage: Model not ready. Exiting.");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Model is not ready yet.'),
          behavior: SnackBarBehavior.fixed,
        ),
      );
      return;
    }
    if (_isSending) {
      print("[ChatScreen] _handleSendMessage: Already sending. Exiting.");
      return;
    }

    _textController.clear();
    final userMessage = Message(text: text, isUser: true);
    final aiPlaceholderMessage = Message(
      text: '',
      isUser: false,
    ); // Placeholder for AI response

    setState(() {
      print(
        "[ChatScreen] _handleSendMessage: setState - _isSending = true, adding user and AI placeholder messages.",
      );
      _isSending = true;
      _messages.add(userMessage);
      _messages.add(aiPlaceholderMessage);
      _shouldAutoScroll =
          true; // Always enable auto-scroll when sending new message
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    try {
      print(
        "[ChatScreen] _handleSendMessage: Calling _chatService.sendMessage.",
      );
      final stream = _chatService.sendMessage(text);
      bool receivedToken = false;
      
      // Create a broadcast stream for both UI updates and TTS
      final broadcastController = StreamController<String>.broadcast();
      
      // Start streaming TTS with the broadcast stream
      if (_streamingTtsService.isReady) {
        print("[ChatScreen] _handleSendMessage: Starting streaming TTS");
        _streamingTtsService.startStreaming(
          broadcastController.stream, 
          speed: 1.3, 
          speakerId: 0,
          messageId: aiPlaceholderMessage.id, // Pass the AI message ID
        ).catchError((e) {
          print("Error with streaming TTS: $e");
        });
      }
      
      // Listen to the original stream and broadcast to both UI and TTS
      try {
        await for (final token in stream) {
          receivedToken = true;
          
          // Broadcast token to TTS stream
          broadcastController.add(token);
          
          if (mounted) {
            setState(() {
              // Update the last message (AI's response) while preserving the original ID
              final currentMessage = _messages.last;
              _messages.last = Message(
                text: currentMessage.text + token,
                isUser: false,
                id: currentMessage.id, // Preserve the original message ID
              );
              print(
                "[ChatScreen] _handleSendMessage: Stream token received: '$token'",
              );
            });
            // Use jumpTo for smoother experience during token streaming
            WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
          }
        }
      } finally {
        // Close the broadcast stream when done
        await broadcastController.close();
      }
      if (!receivedToken) {
        print(
          "[ChatScreen] _handleSendMessage: Stream completed without emitting any tokens.",
        );
      }
    } catch (e) {
      print("[ChatScreen] _handleSendMessage: Error sending message - $e");
      if (mounted) {
        setState(() {
          final currentMessage = _messages.last;
          _messages.last = Message(
            text: "Error: ${e.toString()}",
            isUser: false,
            id: currentMessage.id, // Preserve the original message ID
          );
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sending message: ${e.toString()}'),
            behavior: SnackBarBehavior.fixed,
          ),
        );
      }
    } finally {
      print(
        "[ChatScreen] _handleSendMessage: Finally block - setting _isSending = false.",
      );
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  Future<void> _handlePickModel() async {
    try {
      await _chatService
          .pickAndLoadModel(); // This will trigger listeners if state changes
      // _messages = _chatService.getChatHistory(); // Refresh history
      // setState(() {});
    } catch (e) {
      print("Error picking model: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error picking model: ${e.toString()}'),
            behavior: SnackBarBehavior.fixed,
          ),
        );
      }
    }
  }

  Future<void> _handleRestartChat() async {
    if (!_chatService.isModelReady.value) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Model not loaded, cannot restart chat.'),
          behavior: SnackBarBehavior.fixed,
        ),
      );
      return;
    }
    await _chatService.restartChat();
    setState(() {
      // Manually clear messages since the chat service's clearHistory
      // might not fully clear the fullHistory that getChatHistory() returns
      _messages = []; // Always start with a fresh, modifiable list
    });
    if (!mounted) return; // Check if context is still valid
    
  }

  Future<void> _handleStopGeneration() async {
    print("[ChatScreen] _handleStopGeneration: Called");
    try {
      // Stop both LLM generation and streaming TTS
      await Future.wait([
        _chatService.stopGeneration(),
        _streamingTtsService.stopStreaming(),
      ]);
      print("[ChatScreen] _handleStopGeneration: Generation and streaming TTS stopped successfully");
      
    } catch (e) {
      print("[ChatScreen] _handleStopGeneration: Error stopping generation - $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error stopping generation: ${e.toString()}'),
            behavior: SnackBarBehavior.fixed,
          ),
        );
      }
    }
  }

  Future<void> _handleVoiceRecording() async {
    if (_isRecording) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    try {
      // Request microphone permission
      final status = await Permission.microphone.request();
      if (status != PermissionStatus.granted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Microphone permission is required for voice recording'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 1),
            ),
          );
        }
        return;
      }

      // Check if ASR service is ready
      if (!_asrService.isReady) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('ASR service is not ready yet'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      // Get temporary directory for recording
      final tempDir = await getTemporaryDirectory();
      final fileName = 'voice_recording_${DateTime.now().millisecondsSinceEpoch}.wav';
      _recordingPath = path.join(tempDir.path, fileName);

      // Start recording
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          bitRate: 128000,
          numChannels: 1
        ),
        path: _recordingPath!,
      );

      setState(() {
        _isRecording = true;
      });
      
    } catch (e) {
      print("Error starting recording: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start recording: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _stopRecording() async {
    try {
      await _audioRecorder.stop();
      
      setState(() {
        _isRecording = false;
        _isTranscribing = true;
      });

      if (_recordingPath != null) {
        // Transcribe the recorded audio
        final transcription = await _asrService.transcribeFromFile(_recordingPath!);
        
        setState(() {
          _isTranscribing = false;
        });

        if (transcription.isNotEmpty) {
          // Set the transcribed text in the text field
          _textController.text = transcription;
          
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('No speech detected in the recording'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 1),
              ),
            );
          }
        }

        // Clean up the temporary file
        final file = File(_recordingPath!);
        if (await file.exists()) {
          await file.delete();
        }
        _recordingPath = null;
      }
    } catch (e) {
      print("Error stopping recording: $e");
      setState(() {
        _isRecording = false;
        _isTranscribing = false;
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to process recording: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 1),
          ),
        );
      }
    }
  }

  Future<void> _handlePlayTts(String text) async {
    if (!_ttsService.isReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('TTS service is not ready yet.'),
          behavior: SnackBarBehavior.fixed,
        ),
      );
      return;
    }

    try {
      // Generate a temporary file path for the audio
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final audioPath = path.join(tempDir.path, 'tts_$timestamp.wav');

      // Generate speech and save to file with optimized settings
      await _ttsService.generateSpeechToFile(
        text: text,
        outputPath: audioPath,
        speed: 1.2, // Slightly faster for better responsiveness
        speakerId: 0,
      );

      // Play the audio file
      await _audioPlayer.play(DeviceFileSource(audioPath));

      print("TTS: Generated and playing speech for text: ${text.substring(0, text.length > 50 ? 50 : text.length)}...");

      // Clean up the temporary file after the audio finishes playing
      // Use a one-time listener to avoid memory leaks
      late StreamSubscription subscription;
      subscription = _audioPlayer.onPlayerComplete.listen((_) async {
        final file = File(audioPath);
        if (await file.exists()) {
          await file.delete();
        }
        subscription.cancel(); // Cancel the subscription to avoid memory leaks
      });

    } catch (e) {
      print("Error generating or playing TTS: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to generate or play speech: ${e.toString()}'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.fixed,
          ),
        );
      }
    }
  }



  @override
  Widget build(BuildContext context) {
    // Re-access chatService here if you prefer it to be a local var in build
    // final chatService = Provider.of<ChatService>(context); // Or context.watch<ChatService>()

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gemma Chat'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'Pick Model File',
            onPressed: _handlePickModel,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Restart Chat',
            onPressed: _handleRestartChat,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: ValueListenableBuilder<String?>(
                valueListenable: _chatService.currentModelPath,
                builder: (context, path, child) {
                  return ValueListenableBuilder<bool>(
                    valueListenable: _chatService.isModelReady,
                    builder: (context, isReady, child) {
                      final status =
                          path == null
                              ? "No model selected."
                              : (isReady
                                  ? "Ready"
                                  : (_isModelInitializing
                                      ? "Initializing..."
                                      : "Loading..."));
                      return Text(
                        'Model: ${path ?? "N/A"} ($status)',
                        style: TextStyle(
                          color:
                              path == null || !isReady
                                  ? Colors.orangeAccent
                                  : Colors.greenAccent,
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            if (_isModelInitializing &&
                _chatService.currentModelPath.value != null)
              const Padding(
                padding: EdgeInsets.all(8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(width: 10),
                    Text("Initializing model..."),
                  ],
                ),
              ),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(8.0),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final message = _messages[index];
                  return _ChatMessageBubble(
                    message: message,
                    onPlayTts: message.isUser ? null : () => _handlePlayTts(message.text),
                    ttsService: _ttsService,
                    streamingTtsService: _streamingTtsService,
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      decoration: InputDecoration(
                        hintText: _isRecording 
                            ? 'Recording...' 
                            : _isTranscribing 
                                ? 'Transcribing...' 
                                : 'Enter message or use voice...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20.0),
                        ),
                        filled: true,
                      ),
                      onSubmitted: (_) => _handleSendMessage(),
                      enabled: _chatService.isModelReady.value && !_isSending && !_isRecording && !_isTranscribing,
                    ),
                  ),
                  const SizedBox(width: 8.0),
                  // Voice recording button
                  IconButton(
                    icon: _isRecording
                        ? const Icon(Icons.stop, color: Colors.red)
                        : _isTranscribing
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.mic),
                    onPressed: (_isRecording || _isTranscribing) 
                        ? (_isRecording ? _handleVoiceRecording : null)
                        : (_asrService.isReady ? _handleVoiceRecording : null),
                    style: IconButton.styleFrom(
                      backgroundColor: _isRecording 
                          ? Colors.red.withValues(alpha: 0.2)
                          : Theme.of(context).colorScheme.secondary,
                      foregroundColor: _isRecording 
                          ? Colors.red 
                          : Theme.of(context).colorScheme.onSecondary,
                      padding: const EdgeInsets.all(12),
                    ),
                    tooltip: _isRecording 
                        ? 'Stop Recording' 
                        : _isTranscribing 
                            ? 'Transcribing...' 
                            : 'Voice Recording',
                  ),
                  const SizedBox(width: 8.0),
                  // Show stop button during generation (Android only)
                  ValueListenableBuilder<bool>(
                    valueListenable: _chatService.isGenerating,
                    builder: (context, isGenerating, child) {
                      final showStopButton = isGenerating && !kIsWeb && Platform.isAndroid;
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (showStopButton) ...[
                            IconButton(
                              icon: const Icon(Icons.stop),
                              onPressed: _handleStopGeneration,
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.red,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.all(12),
                              ),
                              tooltip: 'Stop Generation',
                            ),
                            const SizedBox(width: 8.0),
                          ],
                        ],
                      );
                    },
                  ),
                  IconButton(
                    icon:
                        _isSending
                            ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                            : const Icon(Icons.send),
                    onPressed:
                        (_chatService.isModelReady.value && !_isSending && !_isRecording && !_isTranscribing)
                            ? _handleSendMessage
                            : null,
                    style: IconButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Theme.of(context).colorScheme.onPrimary,
                      padding: const EdgeInsets.all(12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatMessageBubble extends StatelessWidget {
  final Message message;
  final VoidCallback? onPlayTts;
  final TtsService ttsService;
  final StreamingTtsService streamingTtsService;

  const _ChatMessageBubble({
    required this.message,
    this.onPlayTts,
    required this.ttsService,
    required this.streamingTtsService,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
        padding: const EdgeInsets.symmetric(vertical: 10.0, horizontal: 14.0),
        decoration: BoxDecoration(
          color:
              message.isUser
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(16.0),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message.text,
              style: TextStyle(
                color:
                    message.isUser
                        ? Theme.of(context).colorScheme.onPrimary
                        : Theme.of(context).colorScheme.onSecondaryContainer,
              ),
            ),
            if (!message.isUser && message.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    // Streaming TTS status indicator - only show for the active message
                    ValueListenableBuilder<String?>(
                      valueListenable: streamingTtsService.activeMessageId,
                      builder: (context, activeMessageId, child) {
                        // Only show indicator if this message is the active one
                        if (activeMessageId != message.id) return const SizedBox.shrink();
                        
                        return ValueListenableBuilder<bool>(
                          valueListenable: streamingTtsService.isStreaming,
                          builder: (context, isStreaming, child) {
                            if (!isStreaming) return const SizedBox.shrink();
                            return ValueListenableBuilder<bool>(
                              valueListenable: streamingTtsService.isPlayingAudio,
                              builder: (context, isPlaying, child) {
                                return Container(
                                  margin: const EdgeInsets.only(right: 8.0),
                                  padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                                  decoration: BoxDecoration(
                                    color: isPlaying ? Colors.green.withOpacity(0.2) : Colors.orange.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: isPlaying ? Colors.green : Colors.orange,
                                      width: 1,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: 12,
                                        height: 12,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: isPlaying ? Colors.green : Colors.orange,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        isPlaying ? 'Speaking' : 'Generating',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: isPlaying ? Colors.green : Colors.orange,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            );
                          },
                        );
                      },
                    ),
                    // Manual TTS play button
                    if (onPlayTts != null)
                      ValueListenableBuilder<bool>(
                        valueListenable: ttsService.isProcessing,
                        builder: (context, isProcessing, child) {
                          return IconButton(
                            onPressed: isProcessing ? null : onPlayTts,
                            icon: isProcessing
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.play_arrow),
                            iconSize: 20,
                            padding: const EdgeInsets.all(4),
                            constraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 28,
                            ),
                            style: IconButton.styleFrom(
                              backgroundColor: Theme.of(context).colorScheme.surface.withOpacity(0.1),
                              foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer.withOpacity(0.7),
                            ),
                            tooltip: 'Play speech',
                          );
                        },
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
