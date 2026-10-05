# Security

## Reporting a vulnerability

Please report security issues privately via
[GitHub security advisories](https://github.com/dpsk/omarchy-clockify/security/advisories/new)
rather than a public issue. You can expect a reply within a few days.

## Threat model

Omarchy shell plugins run unsandboxed inside the long-lived `omarchy-shell`
process, and every plugin shares one QML scene. This plugin is designed so
that the Clockify API key is never part of that scene:

- The key lives only in `~/.config/omarchy/clockify.json`, which the helper
  refuses to read unless it is a regular file (not a symlink), owned by you,
  and not readable by group or others (`chmod 600`).
- Only `clockify.py` reads the key, per request, and exits. The QML panel
  never reads, stores, or passes it, so other plugins cannot reach it through
  the scene graph.
- The key is sent as an HTTP header from inside the Python process. It never
  appears on a command line (`/proc/<pid>/cmdline`), in an environment
  variable, in logs, or in the helper's output.
- Requests go only to a fixed allowlist of Clockify API hosts over verified
  TLS. Redirects are refused so the key header cannot be forwarded to
  another host. Responses are capped at 2 MB and time out after 10 seconds.
- Error messages are fixed strings; unexpected exceptions are reported as an
  opaque "Unexpected error" so no request details leak into the UI.
- Data coming back from Clockify (descriptions, project names, colors) is
  sanitized in the helper and rendered as plain text in QML, so it cannot
  inject rich text, links, or images.

The cache in `~/.cache/omarchy-clockify/` (mode 700) holds only your user id,
workspace id, and project names/colors — never the key.
