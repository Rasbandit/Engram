# Context Doc: Phoenix Channel Event Contract

_Last verified: 2026-04-03_

## Status
Working — design finalized, implementation in progress.

## What This Is
Complete specification for the Phoenix Channel-based real-time sync protocol between the Obsidian plugin and the Engram server.

## Connection & Auth

```
WebSocket connect: wss://engram.fly.dev/socket/websocket?token=<api_key>
  → Socket.connect/3 validates Bearer token, assigns user_id
  → Client joins topic "sync:{user_id}"
  → Channel.join/3 verifies user_id matches socket assignment
  → Presence tracks device (device_id from join params)
```

## Client → Server Events

| Event | Payload | Server Response | Purpose |
|-------|---------|-----------------|---------|
| `push_note` | `{path, content, mtime, version?}` | `{note: {...}, indexing: "queued"}` or `{conflict: true, server_note: {...}}` | Push local change (same contract as POST /notes) |
| `delete_note` | `{path}` | `{ok: true}` | Soft-delete (same as DELETE /notes/{path}) |
| `rename_note` | `{old_path, new_path}` | `{note: {...}}` | Rename (same as POST /notes/rename) |
| `pull_changes` | `{since: ISO8601}` | `{changes: [...], server_time: ISO8601}` | Pull changes since timestamp |
| `push_attachment` | `{path, content_base64, mime_type, mtime}` | `{attachment: {...}}` | Push attachment |

## Server → Client Broadcasts

| Event | Payload | When | Purpose |
|-------|---------|------|---------|
| `note_changed` | `{event_type: "upsert"\|"delete", path, timestamp, kind: "note"\|"attachment"}` | After any note/attachment mutation by ANY device | Real-time sync notification |
| `presence_state` | `{devices: [{device_id, joined_at}]}` | On join | Current connected devices for this user |
| `presence_diff` | `{joins: [...], leaves: [...]}` | On device connect/disconnect | Device change notification |

## Echo Suppression

The server does NOT broadcast `note_changed` back to the device that originated the change. Phoenix Channels supports this via `broadcast_from/3` (broadcasts to all *except* the sender). The plugin's existing 5-second echo cooldown remains as a safety net for edge cases.

## Conflict Flow (over WebSocket)

```
Client sends: push_note {path: "Health/Labs.md", content: "...", version: 3}
Server checks: notes.version for this path

If version matches (3 == 3):
  → Upsert, increment to version 4
  → Reply: {note: {..., version: 4}, indexing: "queued"}
  → broadcast_from: note_changed {path, event_type: "upsert", ...}

If version mismatch (3 != 5):
  → Reply: {conflict: true, server_note: {content: "...", version: 5}}
  → Client performs 3-way merge (base from BaseStore + local + server_note.content)
  → If clean merge: client sends push_note again with merged content + version: 5
  → If conflicts: client shows ConflictModal, user resolves, then push
```

## Plugin Integration

The plugin's `NoteStream` class (SSE) is replaced by a Phoenix Channel client. The `SyncEngine` calls change from `this.api.pushNote()` (HTTP) + `this.stream.onEvent` (SSE) to `this.channel.push("push_note", ...)` + `this.channel.on("note_changed", ...)`. The conflict resolution and 3-way merge logic is unchanged — only the transport layer changes.

## References
- Sync Channel: `lib/engram_web/channels/sync_channel.ex`
- Presence: `lib/engram_web/presence.ex`
- Socket: `lib/engram_web/channels/user_socket.ex`
