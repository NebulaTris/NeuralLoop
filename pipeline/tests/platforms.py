"""Markers for tests that only make sense on some systems."""

import sys

import pytest

WINDOWS = sys.platform == "win32"

# These run small shell or shebang scripts as stand-ins for real programs (opencode, Hermes, a slow child), or
# deliver SIGTERM to the test process. Windows has neither; the Windows app ends a run's tree with taskkill.
posix_only = pytest.mark.skipif(WINDOWS, reason="runs a POSIX script or signal as a stand-in")
