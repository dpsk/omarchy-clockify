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
- Error messages are fixed strings, except that when Clockify rejects a
  request (HTTP 400/422) the panel shows Clockify's own explanation,
  sanitized and cut to 200 characters. Unexpected exceptions are reported as
  an opaque "Unexpected error", so no request details leak into the UI.
- Entry descriptions, edits and the ids of entries to delete are passed to
  the helper over stdin, not argv, so other local users can't read them from
  `/proc/<pid>/cmdline`.
- Edit and delete re-read the entry first and refuse it unless it belongs to
  the configured user and workspace and isn't locked, so even an admin's key
  is never used on someone else's entries. Clockify's update replaces the
  whole entry, so the helper re-sends the fields the panel doesn't show
  (tags, task, billable, custom fields) with every edit.
- Cache files get the same checks as the config: no symlinks, regular
  files only, owned by you, mode 600, inside a directory that is yours and
  mode 700 (tightened automatically if it was created looser).
- Data coming back from Clockify (descriptions, project names, colors) is
  sanitized in the helper and rendered as plain text in QML (the multi-line
  editor included), so it cannot inject rich text, links, or images.
  Descriptions keep their line breaks; every other control or format
  character is dropped.

The cache in `~/.cache/omarchy-clockify/` holds your user id, workspace id,
project names, colors and client names, workspace rules, and a snapshot of
your recent entries, your entries from the last 7 days, and the running entry
(descriptions, entry ids, start and end times, project ids), so the panel can
open without waiting on the network. It
never holds the key. The snapshot is tied to the config file's modification
time and is ignored after setup rewrites the config, for example with a new
key or account. Delete the directory at any time; it is rebuilt on the next
refresh.
