import 'connection_manager.dart';

/// Provisions a fresh, collision-free folder on the gateway host for a
/// name-only Project created from the phone.
///
/// A Project owns its chats by folder (cwd-prefix), so a Project with no
/// folder cannot hold a session on gateways that lack direct assignment.
/// The Desktop app forces the user to pick a folder at create time; the
/// phone flow instead asks the dashboard to make one under the server's
/// projects root (`<locked_root>` when the dashboard is locked, else
/// `<home>/Projects`), so a name-only Project still gets a real home.
///
/// **Never adopts an existing folder.** Every candidate is probed first and
/// skipped when it already exists — the previous failure mode was a new
/// project silently binding to a pre-existing directory of the same name.
/// Only a path this call just created is ever returned.
abstract class ProjectFolderProvisioner {
  /// Returns the absolute path of a newly created folder for [slug], or
  /// `null` when nothing could be provisioned (no projects root reachable,
  /// every candidate taken, or the host refused the write). Callers treat
  /// `null` as "stay folderless", never as a create failure.
  Future<String?> provision(String slug);
}

class DashboardFolderProvisioner implements ProjectFolderProvisioner {
  final DashboardClient dashboard;

  /// Number of `-N` suffix attempts before giving up on provisioning.
  static const _maxCandidates = 50;

  const DashboardFolderProvisioner(this.dashboard);

  /// Returns the absolute path of a newly created folder for [slug], or
  /// `null` when nothing could be provisioned (no projects root reachable,
  /// every candidate taken, or the host refused the write). Callers treat
  /// `null` as "stay folderless", never as a create failure.
  @override
  Future<String?> provision(String slug) async {
    final base = _sanitize(slug);
    if (base.isEmpty) return null;
    final root = await _projectsRoot();
    if (root == null) return null;
    for (var suffix = 0; suffix < _maxCandidates; suffix++) {
      final candidate = suffix == 0 ? '$root/$base' : '$root/$base-$suffix';
      if (await _exists(candidate)) continue;
      try {
        await dashboard.apiPost('files/mkdir', body: {'path': candidate});
        return candidate;
      } catch (error) {
        // A denied write (403: outside the locked root, or a name the
        // server guards like `pairing`) will not change with a suffix —
        // stop rather than burn 50 doomed requests.
        if (error.toString().contains('403')) return null;
        // 409 (a file sits at that path) or a race with a concurrent
        // create: try the next suffix rather than give up.
        continue;
      }
    }
    return null;
  }

  /// The directory new project folders live under.
  ///
  /// A locked dashboard (hosted/container) can only write inside its root,
  /// so the root itself is the projects dir. An unlocked one browses from
  /// the server's home, where `<home>/Projects` is the conventional root.
  Future<String?> _projectsRoot() async {
    try {
      final res = await dashboard.apiGet('files');
      final locked = res['locked_root'];
      if (locked is String && locked.trim().isNotEmpty) {
        return _trimTrailingSlash(locked.trim());
      }
      final home = res['path'];
      if (home is String && home.trim().isNotEmpty) {
        return '${_trimTrailingSlash(home.trim())}/Projects';
      }
    } catch (_) {
      // No readable dashboard means no provisioning; the caller degrades.
    }
    return null;
  }

  /// True when [path] already exists on the host (directory or otherwise).
  ///
  /// Any non-200 (404 missing, 403 unreadable) is read as "not usable as
  /// this name": an existing-but-forbidden path must not be adopted either.
  Future<bool> _exists(String path) async {
    try {
      await dashboard.apiGet('files', queryParameters: {'path': path});
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Keeps the slug filesystem-safe on every host while staying recognizable.
  static String _sanitize(String slug) {
    final cleaned = slug
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^[.\-]+'), '')
        .replaceAll(RegExp(r'[.\-]+$'), '');
    return cleaned;
  }

  static String _trimTrailingSlash(String path) {
    var end = path.length;
    while (end > 1 && (path[end - 1] == '/' || path[end - 1] == r'\')) {
      end--;
    }
    return path.substring(0, end);
  }
}
