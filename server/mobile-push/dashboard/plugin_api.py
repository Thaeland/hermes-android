"""Dashboard imports this as a standalone module, outside the lifecycle package."""

import hashlib
import importlib.util
import sys
from pathlib import Path

from hermes_constants import get_hermes_home

# Load only our private library, not __init__.py (register must remain host-owned).
# A path-qualified name avoids adopting another installed copy's globals.
_source = Path(__file__).resolve().parents[1] / "mobile_push"
_name = "_hermes_mobile_push_" + hashlib.sha256(str(_source).encode()).hexdigest()[:16]
if _name not in sys.modules:
    _spec = importlib.util.spec_from_file_location(
        _name, _source / "__init__.py", submodule_search_locations=[str(_source)]
    )
    _package = importlib.util.module_from_spec(_spec)
    sys.modules[_name] = _package
    _spec.loader.exec_module(_package)
_api = importlib.import_module(_name + ".api")
_config = importlib.import_module(_name + ".config")
# Hermes' _plugin_route_secret_scope validates ?profile and binds get_hermes_home
# in the request context (also copied into sync workers). Do not capture launch
# home or parse client paths/headers here. API stores and lifecycle workers both
# use the selected profile's immutable on-disk paths.
router = _api.create_router(lambda: _config.Profile(Path(get_hermes_home()).resolve()))
