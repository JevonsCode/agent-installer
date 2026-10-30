/// A failure the installer reports with a stable [code].
final class AgentInstallException implements Exception {
  const AgentInstallException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => '$code: $message';
}

Never invalidManifest(String path, String reason) =>
    throw AgentInstallException('invalid_manifest', '$path: $reason');

Never invalidTarget(String path, String reason) =>
    throw AgentInstallException('invalid_target', '$path: $reason');
