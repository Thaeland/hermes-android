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
/// **Never adopts an existing folder.** Every candidate is probed first
/// and only an authoritative 404 counts as free — a 403 (unreadable),
/// 400 (exists but is not a directory) or a transport failure is NOT
/// evidence of absence, and treating it as such was the previous failure
/// mode where a new project silently bound to a pre-existing directory.
/// Because the stock `POST /api/files/mkdir` is `exist_ok=True` (it
/// succeeds even when the directory already exists), the probe alone
/// cannot close the create race, so every successful mkdir is
/// post-verified: the path must answer as a directory with zero entries.
/// A folder that turns out non-empty belongs to someone else and is never
/// returned. Only a path this call just created, proven empty, is ever
/// returned.
abstract class ProjectFolderProvisioner {
  /// Returns the absolute path of a newly created folder for [slug], or
  /// `null` when nothing could be provisioned (no projects root reachable,
  /// every candidate taken, or the host refused the write). Callers treat
  /// `null` as "stay folderless", never as a create failure.
  Future<String?> provision(String slug);
}

/// Outcome of probing one candidate path against the dashboard files
/// router. Only [missing] authorizes creation.
enum _Probe {
  /// 404 — authoritative: nothing lives at this path.
  missing,

  /// 200 — a directory already lives here.
  present,

  /// 403 — unreadable/forbidden. Existence is unknowable; never treat as
  /// free, and a denied write will not change with a suffix, so the caller
  /// stops the whole loop.
  forbidden,

  /// 400 — the path exists but is not a directory (or is otherwise
  /// rejected by the router). Occupied.
  occupied,

  /// Any other status or a transport failure: existence is unknowable.
  /// The candidate is skipped, never created on top of.
  unknown,
}

class DashboardFolderProvisioner implements ProjectFolderProvisioner {
  final DashboardClient dashboard;

  /// Number of `-N` suffix attempts before giving up on provisioning.
  static const _maxCandidates = 50;

  /// Consecutive [ _Probe.unknown ] results before aborting: a server
  /// that cannot answer existence probes cannot safely provision at all,
  /// and suffix-cycling 50 doomed probes buys nothing.
  static const _maxConsecutiveUnknown = 3;

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
    var consecutiveUnknown = 0;
    for (var suffix = 0; suffix < _maxCandidates; suffix++) {
      final candidate = suffix == 0 ? '$root/$base' : '$root/$base-$suffix';
      final probe = await _probe(candidate);
      switch (probe) {
        case _Probe.forbidden:
          // A denied read means the whole region is off-limits to us —
          // suffixing cannot help. Stop rather than burn 50 doomed probes.
          return null;
        case _Probe.present:
        case _Probe.occupied:
          consecutiveUnknown = 0;
          continue;
        case _Probe.unknown:
          // Existence unknowable: skip this name, but don't suffix-spam a
          // server that is failing every probe.
          consecutiveUnknown++;
          if (consecutiveUnknown >= _maxConsecutiveUnknown) return null;
          continue;
        case _Probe.missing:
          // Authoritatively free — attempt the create below.
          break;
      }
      try {
        await dashboard.apiPost('files/mkdir', body: {'path': candidate});
      } catch (error) {
        // A denied write (403: outside the locked root, or a name the
        // server guards like `pairing`) will not change with a suffix —
        // stop rather than burn 50 doomed requests.
        if (error.toString().contains('403')) return null;
        // 409 (a file sits at that path) or a race with a concurrent
        // create: try the next suffix rather than give up.
        consecutiveUnknown = 0;
        continue;
      }
      // The stock mkdir is exist_ok=True: a 200 here does NOT prove we
      // created the directory — a concurrent writer (or a path that
      // appeared between probe and create) passes the same check. The
      // fail-if-exists contract is enforced post-hoc: only a directory
      // that answers as freshly created (zero entries) may be adopted.
      if (await _isFreshlyCreatedEmpty(candidate)) {
        return candidate;
      }
      consecutiveUnknown = 0;
      continue;
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

  /// Classifies one existence probe of [path] against GET /api/files.
  ///
  /// The stock router answers 404 for a missing path, 400 when the path
  /// exists but is not a directory, 403 when it is unreadable/forbidden.
  /// Only the 404 is authoritative absence; everything else keeps the
  /// candidate off the create path.
  Future<_Probe> _probe(String path) async {
    try {
      await dashboard.apiGet('files', queryParameters: {'path': path});
      return _Probe.present;
    } on DashboardHttpException catch (e) {
      return switch (e.statusCode) {
        404 => _Probe.missing,
        403 => _Probe.forbidden,
        400 => _Probe.occupied,
        _ => _Probe.unknown,
      };
    } catch (_) {
      return _Probe.unknown;
    }
  }

  /// Post-create proof: [path] must answer as a directory with zero
  /// entries. A non-empty directory means someone else's folder won the
  /// race and must never be adopted; an unreadable result after a
  /// "successful" mkdir is equally untrustworthy.
  Future<bool> _isFreshlyCreatedEmpty(String path) async {
    try {
      final res = await dashboard.apiGet('files', queryParameters: {'path': path});
      final entries = res['entries'];
      return entries is List && entries.isEmpty;
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
