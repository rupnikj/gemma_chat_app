import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:gemma_chat_app/services/chat_service.dart';
import 'package:gemma_chat_app/screens/settings_screen.dart';
import 'package:flutter_gemma/flutter_gemma.dart'; // For Message class

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

  List<Message> _messages = [];
  bool _isSending = false;
  bool _isModelInitializing = true; // To show loading initially

  late ChatService _chatService;

  @override
  void initState() {
    super.initState();
    _chatService = Provider.of<ChatService>(context, listen: false);

    // Listen to model readiness and path changes to rebuild UI
    _chatService.isModelReady.addListener(_onModelStateChanged);
    _chatService.currentModelPath.addListener(_onModelStateChanged);

    _initializeChatService();
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
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.only(
              bottom: 90.0, // Added margin
              left: 16.0,
              right: 16.0,
            ),
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
    _scrollController.dispose();
    _chatService.isModelReady.removeListener(_onModelStateChanged);
    _chatService.currentModelPath.removeListener(_onModelStateChanged);
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
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
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.only(
            bottom: 90.0, // Added margin
            left: 16.0,
            right: 16.0,
          ),
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
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    try {
      print(
        "[ChatScreen] _handleSendMessage: Calling _chatService.sendMessage.",
      );
      final stream = _chatService.sendMessage(text);
      bool receivedToken = false;
      await for (final token in stream) {
        receivedToken = true;
        if (mounted) {
          setState(() {
            // Update the last message (AI's response)
            _messages.last = Message(
              text: _messages.last.text + token,
              isUser: false,
            );
            print(
              "[ChatScreen] _handleSendMessage: Stream token received: '$token'",
            );
          });
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scrollToBottom(),
          );
        }
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
          _messages.last = Message(
            text: "Error: ${e.toString()}",
            isUser: false,
          );
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sending message: ${e.toString()}'),
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.only(
              bottom: 90.0, // Added margin
              left: 16.0,
              right: 16.0,
            ),
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
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.only(
              bottom: 90.0, // Added margin
              left: 16.0,
              right: 16.0,
            ),
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
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.only(
            bottom: 90.0, // Added margin
            left: 16.0,
            right: 16.0,
          ),
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Chat restarted.'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(
          bottom: 90.0, // Added margin
          left: 16.0,
          right: 16.0,
        ),
      ),
    );
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
                  return _ChatMessageBubble(message: message);
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
                        hintText: 'Enter message...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20.0),
                        ),
                        filled: true,
                      ),
                      onSubmitted: (_) => _handleSendMessage(),
                      enabled: _chatService.isModelReady.value && !_isSending,
                    ),
                  ),
                  const SizedBox(width: 8.0),
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
                        (_chatService.isModelReady.value && !_isSending)
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

  const _ChatMessageBubble({required this.message});

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
        child: Text(
          message.text,
          style: TextStyle(
            color:
                message.isUser
                    ? Theme.of(context).colorScheme.onPrimary
                    : Theme.of(context).colorScheme.onSecondaryContainer,
          ),
        ),
      ),
    );
  }
}
