# Status

This SwiftUI menubar app targets the **v1 Python collector API** (bearer-token FastAPI
daemon on port 8765), which has been retired from `main` — the whole v1 stack is archived
on the `v1-python` branch. The app builds and its 43 tests pass, but it has nothing to talk
to on a v2 (`tailmon`) machine. It will be reworked in a later phase to consume the v2
`tailmon` agent (`:7020`, no auth, tailnet-scoped). Left untouched until then.
