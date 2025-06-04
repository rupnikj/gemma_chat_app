import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_gemma/pigeon.g.dart' show PreferredBackend;
import '../services/chat_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late ChatService _chatService;
  late TextEditingController _maxTokensController;
  late TextEditingController _temperatureController;
  late TextEditingController _topKController;
  late TextEditingController _topPController;
  late TextEditingController _randomSeedController;

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _chatService = Provider.of<ChatService>(context, listen: false);

    // Initialize controllers with current values
    _maxTokensController = TextEditingController(
      text: _chatService.maxTokens.value.toString(),
    );
    _temperatureController = TextEditingController(
      text: _chatService.temperature.value.toStringAsFixed(2),
    );
    _topKController = TextEditingController(
      text: _chatService.topK.value.toString(),
    );
    _topPController = TextEditingController(
      text: _chatService.topP.value.toStringAsFixed(2),
    );
    _randomSeedController = TextEditingController(
      text: _chatService.randomSeed.value?.toString() ?? '1',
    );
  }

  @override
  void dispose() {
    _maxTokensController.dispose();
    _temperatureController.dispose();
    _topKController.dispose();
    _topPController.dispose();
    _randomSeedController.dispose();
    super.dispose();
  }

  Future<void> _updateMaxTokens() async {
    if (_isLoading) return;

    final value = int.tryParse(_maxTokensController.text);
    if (value == null || value < 512 || value > 4096) {
      _showError('Max tokens must be between 512 and 4096');
      return;
    }

    setState(() => _isLoading = true);
    try {
      await _chatService.updateMaxTokens(value);
      _showSuccess('Max tokens updated. Model will reload.');
    } catch (e) {
      _showError('Error updating max tokens: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _updateBackend(PreferredBackend backend) async {
    if (_isLoading) return;

    setState(() => _isLoading = true);
    try {
      await _chatService.updateBackend(backend);
      _showSuccess('Backend updated. Model will reload.');
    } catch (e) {
      _showError('Error updating backend: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _updateChatParameters() async {
    if (_isLoading) return;

    final temperature = double.tryParse(_temperatureController.text);
    final topK = int.tryParse(_topKController.text);
    final topP = double.tryParse(_topPController.text);

    if (temperature == null || temperature < 0 || temperature > 2) {
      _showError('Temperature must be between 0 and 2');
      return;
    }

    if (topK == null || topK < 1) {
      _showError('TopK must be >= 1');
      return;
    }

    if (topP == null || topP < 0 || topP > 1) {
      _showError('TopP must be between 0 and 1');
      return;
    }

    setState(() => _isLoading = true);
    try {
      await _chatService.updateChatParameters(
        newTemperature: temperature,
        newTopK: topK,
        newTopP: topP,
      );
      _showSuccess('Chat parameters updated. Chat session recreated.');
    } catch (e) {
      _showError('Error updating chat parameters: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _updateRandomSeedSettings() async {
    if (_isLoading) return;

    final useFixed = _chatService.useFixedRandomSeed.value;
    int? seedValue;

    if (useFixed) {
      seedValue = int.tryParse(_randomSeedController.text);
      if (seedValue == null || seedValue < 1) {
        _showError('Random seed must be a positive integer (>= 1).');
        return;
      }
    }

    setState(() => _isLoading = true);
    try {
      await _chatService.updateRandomSeedSettings(
        newSeed: useFixed ? seedValue : null, // Pass seed only if fixed is used
        useFixed: useFixed, // Pass the current state of the checkbox
      );
      _showSuccess('Random seed settings updated. Chat session recreated.');
    } catch (e) {
      _showError('Error updating random seed: $e');
    } finally {
      // Update controller text in case the service modified the value (e.g. default)
      if (mounted && useFixed) {
        _randomSeedController.text =
            _chatService.randomSeed.value?.toString() ?? '1';
      } else if (mounted && !useFixed) {
        // Optionally clear or reset the text field when fixed seed is disabled
        // _randomSeedController.text = '1';
      }
      setState(() => _isLoading = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 90.0, left: 16.0, right: 16.0),
      ),
    );
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 90.0, left: 16.0, right: 16.0),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Model Parameters Section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Model Parameters',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'These settings require model reload',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Colors.orange),
                    ),
                    const SizedBox(height: 16),

                    // Max Tokens
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _maxTokensController,
                            decoration: const InputDecoration(
                              labelText: 'Max Tokens',
                              helperText: '512 - 4096',
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _isLoading ? null : _updateMaxTokens,
                          child: const Text('Update'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Backend Selection
                    Text(
                      'Backend',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    ValueListenableBuilder<PreferredBackend>(
                      valueListenable: _chatService.preferredBackend,
                      builder: (context, currentBackend, child) {
                        return Row(
                          children: [
                            Expanded(
                              child: RadioListTile<PreferredBackend>(
                                title: const Text('GPU'),
                                value: PreferredBackend.gpu,
                                groupValue: currentBackend,
                                onChanged:
                                    _isLoading
                                        ? null
                                        : (value) {
                                          if (value != null) {
                                            _updateBackend(value);
                                          }
                                        },
                              ),
                            ),
                            Expanded(
                              child: RadioListTile<PreferredBackend>(
                                title: const Text('CPU'),
                                value: PreferredBackend.cpu,
                                groupValue: currentBackend,
                                onChanged:
                                    _isLoading
                                        ? null
                                        : (value) {
                                          if (value != null) {
                                            _updateBackend(value);
                                          }
                                        },
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Chat Parameters Section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Chat Parameters',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'These settings recreate the chat session',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Colors.blue),
                    ),
                    const SizedBox(height: 16),

                    // Temperature
                    TextField(
                      controller: _temperatureController,
                      decoration: const InputDecoration(
                        labelText: 'Temperature',
                        helperText: '0.0 - 2.0 (creativity)',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // TopK
                    TextField(
                      controller: _topKController,
                      decoration: const InputDecoration(
                        labelText: 'TopK',
                        helperText: '≥ 1 (vocabulary filtering)',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 16),

                    // TopP
                    TextField(
                      controller: _topPController,
                      decoration: const InputDecoration(
                        labelText: 'TopP',
                        helperText: '0.0 - 1.0 (nucleus sampling)',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Update Chat Parameters Button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _updateChatParameters,
                        child:
                            _isLoading
                                ? const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                    SizedBox(width: 8),
                                    Text('Updating...'),
                                  ],
                                )
                                : const Text('Update Chat Parameters'),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Random Seed Settings Section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Random Seed Settings',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Controls the seed for chat response generation. Recreates chat session.',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: Colors.blueGrey),
                    ),
                    const SizedBox(height: 16),
                    ValueListenableBuilder<bool>(
                      valueListenable: _chatService.useFixedRandomSeed,
                      builder: (context, useFixed, child) {
                        return CheckboxListTile(
                          title: const Text('Use Fixed Random Seed'),
                          value: useFixed,
                          onChanged:
                              _isLoading
                                  ? null
                                  : (bool? newValue) async {
                                    if (newValue == null) return;
                                    // Immediately update the service state for the checkbox
                                    // The text field update will be handled by _updateRandomSeedSettings
                                    setState(() => _isLoading = true);
                                    try {
                                      await _chatService
                                          .updateRandomSeedSettings(
                                            useFixed: newValue,
                                          );
                                      if (newValue == false) {
                                        // If disabling fixed seed, we might want to clear/reset the input field
                                        // _randomSeedController.text = '1';
                                      }
                                      _showSuccess(
                                        'Fixed seed setting updated.',
                                      );
                                    } catch (e) {
                                      _showError(
                                        'Error updating fixed seed setting: $e',
                                      );
                                    } finally {
                                      setState(() => _isLoading = false);
                                    }
                                  },
                          controlAffinity: ListTileControlAffinity.leading,
                          activeColor: Theme.of(context).colorScheme.primary,
                        );
                      },
                    ),
                    ValueListenableBuilder<bool>(
                      valueListenable: _chatService.useFixedRandomSeed,
                      builder: (context, useFixed, child) {
                        if (!useFixed) {
                          return const SizedBox.shrink(); // Hide TextField if not using fixed seed
                        }
                        return Padding(
                          padding: const EdgeInsets.only(
                            top: 8.0,
                            left: 16.0,
                            right: 16.0,
                          ),
                          child: TextField(
                            controller: _randomSeedController,
                            decoration: const InputDecoration(
                              labelText: 'Random Seed',
                              helperText:
                                  'Integer >= 1, used if checkbox is ticked',
                              border: OutlineInputBorder(),
                            ),
                            keyboardType: TextInputType.number,
                            enabled: !_isLoading && useFixed,
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed:
                            _isLoading ? null : _updateRandomSeedSettings,
                        child:
                            _isLoading
                                ? const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                    SizedBox(width: 8),
                                    Text('Updating Seed...'),
                                  ],
                                )
                                : const Text('Apply Random Seed Settings'),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Current Values Display
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Current Values',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                    ValueListenableBuilder<int>(
                      valueListenable: _chatService.maxTokens,
                      builder: (context, maxTokens, child) {
                        return Text('Max Tokens: $maxTokens');
                      },
                    ),
                    ValueListenableBuilder<PreferredBackend>(
                      valueListenable: _chatService.preferredBackend,
                      builder: (context, backend, child) {
                        return Text(
                          'Backend: ${backend == PreferredBackend.gpu ? 'GPU' : 'CPU'}',
                        );
                      },
                    ),
                    ValueListenableBuilder<double>(
                      valueListenable: _chatService.temperature,
                      builder: (context, temperature, child) {
                        return Text(
                          'Temperature: ${temperature.toStringAsFixed(2)}',
                        );
                      },
                    ),
                    ValueListenableBuilder<int>(
                      valueListenable: _chatService.topK,
                      builder: (context, topK, child) {
                        return Text('TopK: $topK');
                      },
                    ),
                    ValueListenableBuilder<double>(
                      valueListenable: _chatService.topP,
                      builder: (context, topP, child) {
                        return Text('TopP: ${topP.toStringAsFixed(2)}');
                      },
                    ),
                    ValueListenableBuilder<bool>(
                      valueListenable: _chatService.useFixedRandomSeed,
                      builder: (context, useFixed, child) {
                        return ValueListenableBuilder<int?>(
                          valueListenable: _chatService.randomSeed,
                          builder: (context, seed, child) {
                            final seedText =
                                useFixed
                                    ? (seed?.toString() ?? 'N/A')
                                    : 'Dynamic (new each session)';
                            return Text(
                              'Random Seed: $seedText (Fixed: $useFixed)',
                            );
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
