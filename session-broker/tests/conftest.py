import os
import tempfile

# `app` builds a default broker at import time; keep it off the container-only /data path.
os.environ.setdefault("SESSION_FILE", os.path.join(tempfile.mkdtemp(), "session.json"))
