import { NitroModules } from "react-native-nitro-modules";
import type { NearbyConnections } from "../NearbyConnections.nitro";
import { createEventHandler } from "../utilities/create-event-handler";
import type {
  Connected,
  Disconnected,
  FileReceived,
  FileTransferDirection,
  FileTransferStatus,
  FileTransferUpdate,
  InvitationReceived,
  PeerFound,
  PeerLost,
  TextReceived,
} from "../types/nearby-connections.types";

export const nearbyConnectionsModule =
  NitroModules.createHybridObject<NearbyConnections>("NearbyConnections");

// All handlers are created and wired here so that importing any single function
// from this library guarantees all native callbacks are registered.
export const peerFoundHandler = createEventHandler<PeerFound>();
export const peerLostHandler = createEventHandler<PeerLost>();
export const invitationReceivedHandler = createEventHandler<InvitationReceived>();
export const connectedHandler = createEventHandler<Connected>();
export const disconnectedHandler = createEventHandler<Disconnected>();
export const textReceivedHandler = createEventHandler<TextReceived>();
export const fileTransferUpdateHandler =
  createEventHandler<FileTransferUpdate>();
export const fileReceivedHandler = createEventHandler<FileReceived>();

const isFileTransferDirection = (
  value: string,
): value is FileTransferDirection => value === "incoming" || value === "outgoing";

const isFileTransferStatus = (value: string): value is FileTransferStatus =>
  value === "in_progress" ||
  value === "completed" ||
  value === "cancelled" ||
  value === "failed";

nearbyConnectionsModule.onPeerFound = (peerId, name) =>
  peerFoundHandler.emit({ peerId, name });
nearbyConnectionsModule.onPeerLost = (peerId) =>
  peerLostHandler.emit({ peerId });
nearbyConnectionsModule.onInvitationReceived = (peerId, name) =>
  invitationReceivedHandler.emit({ peerId, name });
nearbyConnectionsModule.onConnected = (peerId, name) =>
  connectedHandler.emit({ peerId, name });
nearbyConnectionsModule.onDisconnected = (peerId) =>
  disconnectedHandler.emit({ peerId });
nearbyConnectionsModule.onTextReceived = (peerId, text) =>
  textReceivedHandler.emit({ peerId, text });
nearbyConnectionsModule.onFileTransferUpdate = (
  transferId,
  peerId,
  direction,
  status,
  bytesTransferred,
  totalBytes,
  name,
  mimeType,
  error,
) => {
  if (!isFileTransferDirection(direction) || !isFileTransferStatus(status)) {
    console.warn(
      `Ignoring invalid native file transfer update: ${direction}/${status}`,
    );
    return;
  }

  fileTransferUpdateHandler.emit({
    transferId,
    peerId,
    direction,
    status,
    bytesTransferred,
    totalBytes,
    name,
    mimeType,
    error,
  });
};
nearbyConnectionsModule.onFileReceived = (
  transferId,
  peerId,
  uri,
  name,
  mimeType,
  size,
) =>
  fileReceivedHandler.emit({
    transferId,
    peerId,
    uri,
    name,
    mimeType,
    size,
  });
