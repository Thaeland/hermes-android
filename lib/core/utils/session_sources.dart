import '../models/session.dart';

const Set<String> kMachineSessionSources = {'cron', 'kanban', 'oneshot'};

// Mirrors the scheduler's persisted IDs, including non-hex legacy job IDs.
final _cronSessionId = RegExp(r'^cron_[A-Za-z0-9][A-Za-z0-9._-]*_\d{8}_\d{6}$');

bool isCronSession(Session session) =>
    session.source == 'cron' ||
    _cronSessionId.hasMatch(session.id) ||
    (session.lineageRootId != null &&
        _cronSessionId.hasMatch(session.lineageRootId!));

bool isMachineSession(Session session) =>
    kMachineSessionSources.contains(session.source) || isCronSession(session);
