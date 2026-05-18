import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_config.dart';

/// Calls the Curatering API RunPod proxy ([`/api/public/runpod/run`], status).
/// `RUNPOD_API_KEY` / `RUNPOD_ENDPOINT_ID` live only on the server (e.g. Railway).
class RunPodService {
  static String _configuredBase = '';

  static void configure(String apiBase) {
    _configuredBase = featureApiBase(apiBase);
  }

  static String get _proxyBase {
    final b = _configuredBase.trim();
    if (b.isEmpty) return '';
    return b.endsWith('/') ? b.substring(0, b.length - 1) : b;
  }

  static void _ensureBase() {
    if (_proxyBase.isEmpty) {
      throw Exception(
        'API_BASE_URL is empty; set --dart-define=API_BASE_URL=... so the RunPod proxy can be reached.',
      );
    }
  }

  static Uri _runUri() => Uri.parse('$_proxyBase/api/public/runpod/run');

  static Uri _statusUri(String jobId) =>
      Uri.parse('$_proxyBase/api/public/runpod/status/${Uri.encodeComponent(jobId)}');

  static Future<String?> generateImage(String prompt) async {
    try {
      _ensureBase();
      final response = await http.post(
        _runUri(),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'input': {'prompt': prompt},
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;

        if (data['status'] == 'COMPLETED') {
          final out = data['output'];
          if (out is Map<String, dynamic>) {
            return out['image'] as String?;
          }
          return null;
        } else if (data['status'] == 'IN_PROGRESS' ||
            data['status'] == 'IN_QUEUE') {
          return null;
        } else {
          throw Exception(
            'Generation failed: ${data['error'] ?? 'Unknown error'}',
          );
        }
      } else {
        _throwHttp(response);
      }
    } catch (e) {
      throw Exception('Failed to generate image: $e');
    }
  }

  static Never _throwHttp(http.Response response) {
    String msg = response.reasonPhrase ?? 'Request failed';
    try {
      final j = jsonDecode(response.body);
      if (j is Map && j['message'] != null) {
        msg = '${j['message']}';
      }
    } catch (_) {
      if (response.body.isNotEmpty) {
        msg = response.body.length > 500
            ? '${response.body.substring(0, 500)}…'
            : response.body;
      }
    }
    throw Exception('HTTP ${response.statusCode}: $msg');
  }

  /// When [initImageBase64] is set, RunPod uses img2img (venue-conditioned generation).
  /// Extract image URL from worker output (including legacy error+uploaded cases).
  static String? _imageUrlFromOutput(Map<String, dynamic>? out) {
    if (out == null) return null;
    final direct = out['image_url'] as String?;
    if (direct != null && direct.isNotEmpty) return direct;
    final diag = out['diagnostics'];
    if (diag is Map) {
      final uploaded = diag['public_url'] as String?;
      if (uploaded != null && uploaded.isNotEmpty) return uploaded;
    }
    return null;
  }

  static Future<String?> generateImageWithPolling(
    String prompt, {
    String? user_id,
    String? initImageBase64,
    double strength = 0.65,
    int numInferenceSteps = 18,
    Map<String, dynamic>? designMeta,
  }) async {
    try {
      _ensureBase();
      final input = <String, dynamic>{
        'prompt': prompt,
        'num_inference_steps': numInferenceSteps,
        if (designMeta != null) ...designMeta,
      };
      final uid = user_id?.trim();
      if (uid != null && uid.isNotEmpty) {
        input['user_id'] = uid;
      }
      // Must be set after designMeta so venue image is never overwritten.
      final init = initImageBase64?.trim();
      if (init != null && init.isNotEmpty) {
        input['init_image_base64'] = init;
        input['strength'] = strength;
      }
      final response = await http.post(
        _runUri(),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'input': input}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;

        if (data['status'] == 'COMPLETED') {
          final out = data['output'] is Map<String, dynamic>
              ? data['output'] as Map<String, dynamic>
              : null;
          final imageUrl = _imageUrlFromOutput(out);
          if (imageUrl != null) return imageUrl;
          if (out != null && out['status'] == 'error') {
            throw Exception(
              out['message']?.toString() ?? 'Worker returned status error',
            );
          }
          return null;
        } else if (data['status'] == 'IN_PROGRESS' ||
            data['status'] == 'IN_QUEUE') {
          final jobId = data['id']?.toString();
          if (jobId == null || jobId.isEmpty) {
            throw Exception('RunPod response missing job id');
          }
          return await _pollForCompletion(jobId);
        } else {
          throw Exception(
            'Generation failed: ${data['error'] ?? 'Unknown error'}',
          );
        }
      } else {
        _throwHttp(response);
      }
    } catch (e) {
      throw Exception('Failed to generate image: $e');
    }
  }

  /// RunPod execution timeout is often 600s; poll long enough for cold GPU + inference.
  static const int _pollIntervalSeconds = 5;
  static const int _maxPollAttempts = 130;

  static String _formatRunpodFailure(Map<String, dynamic> data) {
    final err = data['error']?.toString() ?? 'Unknown error';
    if (err.contains('executionTimeout')) {
      return 'AI generation exceeded the server time limit (~10 min). '
          'Redeploy the RunPod worker image, then try again — the second attempt is usually faster.';
    }
    return 'Job failed: $err';
  }

  static Future<String?> _pollForCompletion(String jobId) async {
    int attempts = 0;
    Object? lastError;

    while (attempts < _maxPollAttempts) {
      await Future.delayed(
        const Duration(seconds: _pollIntervalSeconds),
      );
      attempts++;

      try {
        final response = await http.get(_statusUri(jobId));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;

          if (data['status'] == 'COMPLETED') {
            final out = data['output'] is Map<String, dynamic>
                ? data['output'] as Map<String, dynamic>
                : null;
            final imageUrl = _imageUrlFromOutput(out);
            if (imageUrl != null) return imageUrl;
            if (out != null && out['status'] == 'error') {
              throw Exception(
                out['message']?.toString() ?? 'Worker returned status error',
              );
            }
            return null;
          }
          if (data['status'] == 'FAILED') {
            throw Exception(_formatRunpodFailure(data));
          }
        }
      } on Exception catch (e) {
        final msg = e.toString();
        if (msg.contains('Job failed') ||
            msg.contains('AI generation exceeded') ||
            msg.contains('Worker returned')) {
          rethrow;
        }
        lastError = e;
        print('Polling error (attempt $attempts): $e');
      } catch (e) {
        lastError = e;
        print('Polling error (attempt $attempts): $e');
      }
    }

    if (lastError is Exception) {
      throw lastError;
    }
    final totalSeconds = _maxPollAttempts * _pollIntervalSeconds;
    throw Exception(
      'Job timed out after ${totalSeconds}s waiting for the AI worker. Try again in a moment.',
    );
  }

  static Future<Map<String, dynamic>> startGenerationJob(String prompt) async {
    _ensureBase();
    final response = await http.post(
      _runUri(),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'input': {'prompt': prompt},
      }),
    );

    if (response.statusCode != 200) {
      _throwHttp(response);
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>> getJobStatus(String jobId) async {
    _ensureBase();
    final response = await http.get(_statusUri(jobId));

    if (response.statusCode != 200) {
      _throwHttp(response);
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static Future<String?> pollForResult(
    String jobId, {
    int maxAttempts = _maxPollAttempts,
    int intervalSeconds = _pollIntervalSeconds,
  }) async {
    for (var i = 0; i < maxAttempts; i++) {
      await Future.delayed(Duration(seconds: intervalSeconds));

      try {
        final status = await getJobStatus(jobId);

        if (status['status'] == 'COMPLETED') {
          final out = status['output'];
          if (out is Map<String, dynamic>) {
            return out['image'] as String?;
          }
          return null;
        } else if (status['status'] == 'FAILED') {
          throw Exception('Job failed: ${status['error'] ?? 'Unknown error'}');
        }

        print(
          'Job $jobId status: ${status['status']} (attempt ${i + 1}/$maxAttempts)',
        );
      } catch (e) {
        print('Polling error (attempt ${i + 1}/$maxAttempts): $e');
        if (i == maxAttempts - 1) rethrow;
      }
    }

    throw Exception('Job timed out after $maxAttempts attempts');
  }

  static Future<String?> generateImageWithPollingSimple(String prompt) async {
    final jobResult = await startGenerationJob(prompt);
    final jobId = jobResult['id'] as String;

    return await pollForResult(jobId);
  }
}
