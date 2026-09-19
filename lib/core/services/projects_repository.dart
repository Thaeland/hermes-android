/// Offline-aware access to the server-owned Hermes Projects.
///
/// Sits between the UI and [ProjectsGatewayClient]:
///
/// - the gateway stays the source of truth;
/// - the last good listing is cached per connection so the app opens with
///   content instead of a spinner, clearly marked as stale;
/// - mutations apply optimistically and roll back on failure;
/// - an older gateway degrades to a labelled compatibility mode rather than
///   an error screen;
/// - local Spaces can be *previewed* against server Projects without writing
///   anything, which is the safe first half of the migration.
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/hermes_project.dart';
import '../models/project_sessions_tree.dart';
import '../models/projects_tree_overview.dart';
import '../models/session.dart';
import 'chat_space_store.dart';
import 'project_folder_provisioner.dart';
import 'projects_gateway_client.dart';

/// Whether this gateway offers the native `projects.*` family.
enum ProjectsSupport {
  /// Not probed yet.
  unknown,

  /// The gateway answers `projects.*`.
  native,

  /// The gateway predates Projects; local grouping remains the only option.
  unsupported,
}

/// An immutable snapshot the UI can render directly.
class ProjectsView {
  final List<HermesProject> projects;
  final List<HermesProject> archived;
  final String? activeId;
  final ProjectsSupport support;

  /// True when these projects came from the cache rather than a live read.
  final bool isStale;

  /// The failure that forced the fallback to cache, if any.
  final Object? error;

  const ProjectsView({
    this.projects = const [],
    this.archived = const [],
    this.activeId,
    this.support = ProjectsSupport.unknown,
    this.isStale = false,
    this.error,
  });

  static const empty = ProjectsView();

  bool get isEmpty => projects.isEmpty && archived.isEmpty;

  HermesProject? get activeProject {
    for (final project in projects) {
      if (project.id == activeId) return project;
    }
    return null;
  }

  ProjectsView copyWith({
    List<HermesProject>? projects,
    List<HermesProject>? archived,
    String? activeId,
    bool clearActiveId = false,
    ProjectsSupport? support,
    bool? isStale,
    Object? error,
    bool clearError = false,
  }) {
    return ProjectsView(
      projects: projects ?? this.projects,
      archived: archived ?? this.archived,
      activeId: clearActiveId ? null : (activeId ?? this.activeId),
      support: support ?? this.support,
      isStale: isStale ?? this.isStale,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// One local Space matched (or not) against the server Projects.
class SpaceMigrationEntry {
  final ChatSpace space;

  /// The server Project this Space maps onto, or null when it must be created.
  final HermesProject? matchedProject;

  /// How many local chats are assigned to this Space.
  final int sessionCount;

  const SpaceMigrationEntry({
    required this.space,
    required this.matchedProject,
    required this.sessionCount,
  });

  bool get needsCreation => matchedProject == null;
}

/// What a completed migration actually did.
class SpaceMigrationResult {
  /// Spaces turned into new server Projects.
  final int createdProjects;

  /// Spaces the server already carried under the same (normalized) name.
  final int alreadyLinked;

  /// Chats now owned by their server Project.
  final int linkedSessions;

  /// Chats whose assignment failed or whose gateway predates the binding RPC.
  final int unlinkedSessions;

  /// Space or `space/session` → the error that stopped it.
  final Map<String, Object> failures;

  const SpaceMigrationResult({
    required this.createdProjects,
    required this.alreadyLinked,
    required this.linkedSessions,
    required this.unlinkedSessions,
    required this.failures,
  });

  /// Complete means every Project exists and every assigned chat moved.
  bool get isComplete => failures.isEmpty && unlinkedSessions == 0;
}

/// A read-only description of what a Spaces migration *would* do.
class SpaceMigrationPlan {
  final List<SpaceMigrationEntry> entries;

  const SpaceMigrationPlan(this.entries);

  bool get isEmpty => entries.isEmpty;

  int get projectsToCreate =>
      entries.where((entry) => entry.needsCreation).length;

  int get sessionsToLink =>
      entries.fold(0, (total, entry) => total + entry.sessionCount);
}

/// One project's chats, as an immutable snapshot the UI can render directly.
///
/// Deliberately separate from [ProjectsView]: opening a project must never be
/// able to disturb the Projects list. A gateway that serves `projects.list`
/// but predates `projects.project_sessions` reports [ProjectsSupport
/// .unsupported] *here* while the pane behind it keeps working.
class ProjectSessionsView {
  final String projectId;

  /// The server's own project → repo → lane grouping, when it answered one.
  final ProjectSessionsTree? tree;

  /// Every chat in the project, flattened in server order.
  final List<Session> sessions;

  final ProjectsSupport support;

  /// True when these chats came from an earlier read that a failure has since
  /// left unrefreshed.
  final bool isStale;

  /// The failure that prevented a live read, if any.
  final Object? error;

  const ProjectSessionsView({
    required this.projectId,
    this.tree,
    this.sessions = const [],
    this.support = ProjectsSupport.unknown,
    this.isStale = false,
    this.error,
  });

  bool get isEmpty => sessions.isEmpty;
}

/// Repository over the gateway Projects family.
class ProjectsRepository {
  final ProjectsGatewayClient client;
  final SharedPreferences preferences;
  final String connectionId;

  /// Optional folder auto-provisioner for name-only creates.
  ///
  /// When set, a Project created without any folder gets a freshly made
  /// directory bound as its primary — the phone cannot pick folders the
  /// way Desktop does, and a folderless Project cannot hold chats on
  /// gateways without direct assignment. The provisioner never adopts a
  /// pre-existing folder, so this can only ever bind a directory it just
  /// created itself.
  final ProjectFolderProvisioner? folderProvisioner;

  final _controller = StreamController<ProjectsView>.broadcast();
  ProjectsView _current = ProjectsView.empty;

  /// Last good drill-in per project, so re-entering one opens with content.
  final _sessionsCache = <String, ProjectSessionsView>{};

  /// In-flight drill-in reads, so two opens racing each other share one call.
  final _sessionsInFlight = <String, Future<ProjectSessionsView>>{};

  /// Set once the gateway proves it predates `projects.project_sessions`.
  bool _sessionsUnsupported = false;

  ProjectsTreeOverview? _overviewCache;
  bool _overviewUnsupported = false;

  ProjectsRepository({
    required this.client,
    required this.preferences,
    required this.connectionId,
    this.folderProvisioner,
  });

  /// Emits after every state change, including optimistic ones.
  Stream<ProjectsView> get changes => _controller.stream;

  ProjectsView get current => _current;

  String get _cacheKey => 'projects_cache_v1_$connectionId';

  /// Reads the cached listing without touching the network.
  ///
  /// Always marked stale: the app may show it instantly, but must not present
  /// it as confirmed server state.
  Future<ProjectsView> loadCached() async {
    final cached = _readCache();
    _emit(cached);
    return cached;
  }

  /// Refreshes from the gateway, falling back to cache on transport failure.
  Future<ProjectsView> refresh() async {
    try {
      final snapshot = await client.list();
      final view = ProjectsView(
        projects: snapshot.active,
        archived: snapshot.archived,
        activeId: snapshot.activeId,
        support: ProjectsSupport.native,
      );
      await _writeCache(view);
      return _emit(view);
    } on ProjectsUnsupportedException {
      // Not a failure: this gateway simply has no Projects. Keep the surface
      // calm and let the caller offer local grouping instead.
      return _emit(const ProjectsView(support: ProjectsSupport.unsupported));
    } catch (error) {
      final cached = _readCache();
      return _emit(
        cached.copyWith(
          support: _current.support == ProjectsSupport.unknown
              ? cached.support
              : _current.support,
          isStale: true,
          error: error,
        ),
      );
    }
  }

  /// Reads the server's cheap all-Project tree used for card counts and Inbox.
  ///
  /// Older gateways may support `projects.list` without this sibling method;
  /// that degrades only the extra metadata, never the Projects list itself.
  Future<ProjectsTreeOverview> overview({bool refresh = false}) async {
    if (_current.support == ProjectsSupport.unsupported ||
        _overviewUnsupported) {
      return ProjectsTreeOverview.empty;
    }
    final cached = _overviewCache;
    if (!refresh && cached != null) return cached;
    try {
      final overview = await client.tree();
      _overviewCache = overview;
      return overview;
    } on ProjectsUnsupportedException {
      _overviewUnsupported = true;
      return ProjectsTreeOverview.empty;
    }
  }

  Future<HermesProject> create(String name, {bool select = false}) async {
    _requireSupported();
    final trimmed = name.trim();
    final previous = _current;
    final placeholder = HermesProject(
      id: 'pending:${DateTime.now().microsecondsSinceEpoch}',
      slug: trimmed.toLowerCase().replaceAll(RegExp(r'\s+'), '-'),
      name: trimmed,
    );
    _emit(
      previous.copyWith(
        projects: [...previous.projects, placeholder],
        clearError: true,
      ),
    );

    try {
      var created = await client.create(name: trimmed, use: select);
      if (created.folders.isEmpty && folderProvisioner != null) {
        // Name-only create: give the Project a folder it owns outright.
        // A provisioning or bind failure must not undo the create — the
        // Project exists and stays folderless (honest, and the user can
        // add a folder later); only the auto-home is lost.
        final folder = await folderProvisioner!.provision(created.slug);
        if (folder != null) {
          try {
            created = await client.addFolder(
              id: created.id,
              path: folder,
              label: created.name,
              isPrimary: true,
            );
          } catch (_) {}
        }
      }
      final view = previous.copyWith(
        projects: [...previous.projects, created],
        activeId: select ? created.id : null,
        clearError: true,
      );
      await _writeCache(view);
      _emit(view);
      return created;
    } catch (_) {
      _emit(previous);
      rethrow;
    }
  }

  Future<HermesProject> rename(String id, String name) async {
    _requireSupported();
    final previous = _current;
    _emit(previous.copyWith(projects: _renamed(previous.projects, id, name)));

    try {
      final updated = await client.rename(id: id, name: name);
      final view = previous.copyWith(
        projects: [
          for (final project in previous.projects)
            if (project.id == id) updated else project,
        ],
        clearError: true,
      );
      await _writeCache(view);
      _emit(view);
      return updated;
    } catch (_) {
      _emit(previous);
      rethrow;
    }
  }

  /// Archives a project (reversible), or restores it when [restore] is true.
  Future<void> archive(String id, {bool restore = false}) async {
    _requireSupported();
    final previous = _current;
    _emit(_locallyArchived(previous, id, restore: restore));

    try {
      final snapshot = await client.archive(id, restore: restore);
      final view = previous.copyWith(
        projects: snapshot.active,
        archived: snapshot.archived,
        activeId: snapshot.activeId,
        clearActiveId: snapshot.activeId == null,
        clearError: true,
      );
      await _writeCache(view);
      _emit(view);
    } catch (_) {
      _emit(previous);
      rethrow;
    }
  }

  /// Hard-deletes one Project while preserving its conversations.
  ///
  /// The Gateway cascades only Project metadata and assignment rows; chat
  /// sessions remain stored and therefore fall back to Unassigned. The list is
  /// updated optimistically and fully restored if the server rejects the write.
  Future<void> delete(String id) async {
    _requireSupported();
    final previous = _current;
    final optimistic = previous.copyWith(
      projects: [
        for (final project in previous.projects)
          if (project.id != id) project,
      ],
      archived: [
        for (final project in previous.archived)
          if (project.id != id) project,
      ],
      clearActiveId: previous.activeId == id,
      clearError: true,
    );
    _emit(optimistic);

    try {
      final snapshot = await client.delete(id);
      final view = previous.copyWith(
        projects: snapshot.active,
        archived: snapshot.archived,
        activeId: snapshot.activeId,
        clearActiveId: snapshot.activeId == null,
        clearError: true,
      );
      _sessionsCache.remove(id);
      await _writeCache(view);
      _emit(view);
    } catch (_) {
      _emit(previous);
      rethrow;
    }
  }

  /// Persists the authoritative server-side Project for one conversation.
  ///
  /// Callers must complete this before opening a newly drafted Project chat;
  /// otherwise the chat would initially exist under Unassigned and the user's
  /// selection would be silently lost.
  Future<void> assignSession(String sessionId, String? projectId) async {
    _requireSupported();
    await client.assignSession(sessionId: sessionId, projectId: projectId);
  }

  Future<void> setActive(String? id) async {
    _requireSupported();
    final previous = _current;
    _emit(previous.copyWith(activeId: id, clearActiveId: id == null));

    try {
      final activeId = await client.setActive(id);
      final view = previous.copyWith(
        activeId: activeId,
        clearActiveId: activeId == null,
        clearError: true,
      );
      await _writeCache(view);
      _emit(view);
    } catch (_) {
      _emit(previous);
      rethrow;
    }
  }

  /// Describes how local Spaces map onto server Projects.
  ///
  /// Purely read-only: nothing is created, linked, or deleted. The user sees
  /// this plan before any migration runs, and the local store stays intact
  /// until the server read-back confirms every assignment.
  SpaceMigrationPlan planMigration(ChatSpaceState state) {
    String normalize(String value) =>
        value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

    final byName = <String, HermesProject>{
      for (final project in [..._current.projects, ..._current.archived])
        normalize(project.name): project,
    };

    final counts = <String, int>{};
    for (final spaceId in state.assignments.values) {
      counts[spaceId] = (counts[spaceId] ?? 0) + 1;
    }

    return SpaceMigrationPlan([
      for (final space in state.spaces)
        SpaceMigrationEntry(
          space: space,
          matchedProject: byName[normalize(space.name)],
          sessionCount: counts[space.id] ?? 0,
        ),
    ]);
  }

  /// Executes the plan described by [planMigration].
  ///
  /// Gated behind step 7 of Phase 0 (real Gateway smoke test on a device),
  /// which passed once the preview rendered correctly against a live gateway.
  ///
  /// Three properties this must keep:
  ///
  /// * **Idempotent.** Matching is by normalized name, so a second run creates
  ///   nothing. A user who taps twice must not end up with duplicate projects.
  /// * **Non-destructive.** The local Spaces store is never cleared. It is the
  ///   only record of the user's grouping until the server can hold chat →
  ///   project links, and a partial migration that wiped it would lose data
  ///   that cannot be reconstructed.
  /// * **Honest.** A failure part-way keeps what already succeeded and reports
  ///   the rest in [SpaceMigrationResult.failures] rather than throwing away
  ///   the successful writes or claiming a clean run.
  Future<SpaceMigrationResult> migrateSpaces(ChatSpaceState state) async {
    // A legacy gateway must fail loudly: silently no-opping would let the UI
    // report a migration that never happened.
    _requireSupported();

    final plan = planMigration(state);
    var created = 0;
    var matched = 0;
    var linkedSessions = 0;
    var unlinkedSessions = 0;
    var assignmentsSupported = true;
    final failures = <String, Object>{};

    for (final entry in plan.entries) {
      HermesProject target;
      if (entry.matchedProject case final existing?) {
        target = existing;
        matched++;
      } else {
        try {
          // `use: false` — migrating is bookkeeping, not navigation. Stealing
          // the active project would move the user somewhere they didn't ask
          // to go.
          target = await create(entry.space.name, select: false);
          created++;
        } catch (error) {
          failures[entry.space.name] = error;
          unlinkedSessions += entry.sessionCount;
          continue;
        }
      }

      final sessionIds = state.assignments.entries
          .where((assignment) => assignment.value == entry.space.id)
          .map((assignment) => assignment.key);
      for (final sessionId in sessionIds) {
        if (!assignmentsSupported) {
          unlinkedSessions++;
          continue;
        }
        try {
          await client.assignSession(
            sessionId: sessionId,
            projectId: target.id,
          );
          linkedSessions++;
        } on ProjectsUnsupportedException catch (error) {
          // A gateway can support the Projects family but predate this sibling.
          // Stop probing after the first definitive answer and leave all local
          // Spaces intact so nothing is lost.
          assignmentsSupported = false;
          unlinkedSessions++;
          failures['${entry.space.name}/$sessionId'] = error;
        } catch (error) {
          unlinkedSessions++;
          failures['${entry.space.name}/$sessionId'] = error;
        }
      }
    }

    return SpaceMigrationResult(
      createdProjects: created,
      alreadyLinked: matched,
      linkedSessions: linkedSessions,
      unlinkedSessions: unlinkedSessions,
      failures: failures,
    );
  }

  /// The chats inside one project, as the server groups them.
  ///
  /// Cached per project: re-entering a project shows the previous contents
  /// immediately and costs no request unless [refresh] is set. A failure never
  /// discards chats already read — losing the list because the socket blinked
  /// is worse than showing it behind an offline notice.
  Future<ProjectSessionsView> projectSessions(
    String id, {
    bool refresh = false,
  }) async {
    final cached = _sessionsCache[id];
    if (!refresh && cached != null) return cached;

    // A gateway already proven to lack the family, or the drill-in method
    // itself, is never probed again: the answer cannot change without a
    // reconnect, and every wasted round trip is a slower project screen.
    if (_current.support == ProjectsSupport.unsupported ||
        _sessionsUnsupported) {
      return ProjectSessionsView(
        projectId: id,
        support: ProjectsSupport.unsupported,
        sessions: cached?.sessions ?? const [],
        tree: cached?.tree,
      );
    }

    final inFlight = _sessionsInFlight[id];
    if (inFlight != null) return inFlight;

    final request = _readProjectSessions(id, cached);
    _sessionsInFlight[id] = request;
    try {
      return await request;
    } finally {
      _sessionsInFlight.remove(id);
    }
  }

  Future<ProjectSessionsView> _readProjectSessions(
    String id,
    ProjectSessionsView? cached,
  ) async {
    try {
      final tree = await client.projectSessions(id);
      final view = ProjectSessionsView(
        projectId: id,
        tree: tree,
        sessions: _sessionsOf(tree),
        support: ProjectsSupport.native,
      );
      _sessionsCache[id] = view;
      return view;
    } on ProjectsUnsupportedException {
      // Only this call is missing. The Projects list stays exactly as it is:
      // flipping the whole pane into compatibility mode would hide server
      // projects the gateway serves perfectly well.
      _sessionsUnsupported = true;
      return ProjectSessionsView(
        projectId: id,
        support: ProjectsSupport.unsupported,
        sessions: cached?.sessions ?? const [],
        tree: cached?.tree,
      );
    } catch (error) {
      return ProjectSessionsView(
        projectId: id,
        tree: cached?.tree,
        sessions: cached?.sessions ?? const [],
        support: _current.support,
        isStale: cached != null,
        error: error,
      );
    }
  }

  /// The chats to render for [tree].
  ///
  /// Lane grouping is preferred because it is what the server ranked, but a
  /// project whose chats carry no repo/cwd produces no lanes at all while the
  /// server still lists them in `previewSessions`. Showing "no chats yet" then
  /// would be a lie the user cannot resolve from the phone.
  static List<Session> _sessionsOf(ProjectSessionsTree? tree) {
    if (tree == null) return const [];
    final grouped = tree.allSessions;
    return grouped.isNotEmpty ? grouped : tree.previewSessions;
  }

  Future<void> close() async {
    await _controller.close();
  }

  void _requireSupported() {
    if (_current.support == ProjectsSupport.unsupported) {
      throw const ProjectsUnsupportedException(
        'projects',
        'This Hermes gateway does not support server-side projects',
      );
    }
  }

  static List<HermesProject> _renamed(
    List<HermesProject> projects,
    String id,
    String name,
  ) {
    return [
      for (final project in projects)
        if (project.id == id)
          HermesProject(
            id: project.id,
            slug: project.slug,
            name: name.trim(),
            description: project.description,
            icon: project.icon,
            color: project.color,
            boardSlug: project.boardSlug,
            primaryPath: project.primaryPath,
            archived: project.archived,
            createdAt: project.createdAt,
            folders: project.folders,
          )
        else
          project,
    ];
  }

  static ProjectsView _locallyArchived(
    ProjectsView view,
    String id, {
    required bool restore,
  }) {
    if (restore) {
      final restored = view.archived.where((p) => p.id == id).toList();
      return view.copyWith(
        projects: [...view.projects, ...restored],
        archived: view.archived.where((p) => p.id != id).toList(),
      );
    }
    final removed = view.projects.where((p) => p.id == id).toList();
    return view.copyWith(
      projects: view.projects.where((p) => p.id != id).toList(),
      archived: [...view.archived, ...removed],
    );
  }

  ProjectsView _emit(ProjectsView view) {
    _current = view;
    if (!_controller.isClosed) _controller.add(view);
    return view;
  }

  ProjectsView _readCache() {
    final raw = preferences.getString(_cacheKey);
    if (raw == null || raw.isEmpty) {
      return const ProjectsView(isStale: true);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const ProjectsView(isStale: true);
      final map = Map<String, dynamic>.from(decoded);
      final snapshot = ProjectsSnapshot.fromJson({
        'projects': map['projects'],
        'active_id': map['active_id'],
      });
      return ProjectsView(
        projects: snapshot.active,
        archived: snapshot.archived,
        activeId: snapshot.activeId,
        support: ProjectsSupport.native,
        isStale: true,
      );
    } catch (_) {
      // A corrupt cache must never block the app; drop it silently.
      return const ProjectsView(isStale: true);
    }
  }

  Future<void> _writeCache(ProjectsView view) async {
    final payload = jsonEncode({
      'projects': [
        for (final project in [...view.projects, ...view.archived])
          _projectToJson(project),
      ],
      'active_id': view.activeId,
    });
    await preferences.setString(_cacheKey, payload);
  }

  static Map<String, dynamic> _projectToJson(HermesProject project) => {
    'id': project.id,
    'slug': project.slug,
    'name': project.name,
    'description': project.description,
    'icon': project.icon,
    'color': project.color,
    'board_slug': project.boardSlug,
    'primary_path': project.primaryPath,
    'archived': project.archived,
    'created_at': project.createdAt,
    'folders': [
      for (final folder in project.folders)
        {
          'path': folder.path,
          'label': folder.label,
          'is_primary': folder.isPrimary,
          'added_at': folder.addedAt,
        },
    ],
  };
}
