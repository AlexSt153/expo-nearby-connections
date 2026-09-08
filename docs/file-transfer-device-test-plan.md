# File transfer device test plan

Run this matrix on two physical devices using the example app. Use two Android
devices for Android cases and two iOS devices for iOS cases; cross-platform file
transfer is not supported.

## Required matrix

| Case | Android | iOS | Expected result |
| --- | --- | --- | --- |
| Small file | Yes | Yes | Progress ends in `completed`; receiver URI is readable and metadata matches. |
| Large file | Yes | Yes | Transfer completes without a Base64/JS memory spike. |
| Content URI | Yes | N/A | A document-picker `content://` URI transfers and its descriptor is released. |
| Cancel outgoing | Yes | Yes | Sender emits one `cancelled` terminal update; receiver does not expose a file. |
| Cancel incoming | Yes | Yes | Receiver emits one `cancelled` terminal update and removes temporary data. |
| Disconnect mid-transfer | Yes | Yes | Active transfers emit one `failed` terminal update and partial files are removed. |
| Concurrent duplicate names | Yes | Yes | Both transfers complete in separate transfer-ID directories. |
| Text during file transfer | Yes | Yes | Text events remain text events and the file metadata is never exposed as text. |

## Protocol and ordering checks

Test with temporary instrumentation or a compatible fixture peer:

- Deliver the metadata control envelope before the native file/resource.
- Deliver the native file/resource before its metadata envelope.
- Omit metadata and confirm the receiver fails and removes the cached payload
  after the metadata timeout.
- Send an envelope with an unsupported version and confirm it is consumed as an
  invalid control message rather than emitted through `onTextReceived`.
- Use names containing `../`, path separators, control characters, and duplicate
  names; confirm every result stays under
  `ExpoNearbyConnections/<transfer-id>/<sanitized-name>`.

For every case, record both peers' `onFileTransferUpdate` sequences and confirm
that each transfer ID has exactly one terminal status.

## iOS session teardown regression

Run on two physical iOS devices, including a receiver that leaves the receiving
screen while progress still displays 0%, and repeat after visible progress:

- Leave the receiver screen, then reconnect and retry the unacknowledged file.
- Background either device, restore it, and reconnect.
- Interrupt connectivity while receiving and restore it.
- Repeat quick disconnect/reconnect cycles to exercise callbacks from old sessions.
- Exercise explicit single-transfer cancellation separately; it must still cancel.

Record session identity, transfer identity, byte progress, disconnect reason, and
terminal events without file contents or personal data. Confirm there is no native
crash, each transfer has at most one terminal event, and an old session cannot
populate the replacement session's incoming transfer state. Session teardown must
finish local cleanup before returning; the framework's transport shutdown remains
asynchronous.

The teardown mitigation removes redundant per-transfer Progress cancellation when
MCSession itself is disconnected (or reports a peer disconnected). Explicit
transfer cancellation still uses Progress.cancel(). This does not establish the
root cause of an Apple-framework crash; native device testing remains required.
