export { Strategy } from "../NearbyConnections.nitro";

export interface BasePeer {
  peerId: string;
  name: string;
}

export interface PeerFound extends BasePeer {}

export type OnPeerFound = (data: PeerFound) => void;

export interface PeerLost extends Pick<BasePeer, "peerId"> {}

export type OnPeerLost = (data: PeerLost) => void;

export interface InvitationReceived extends BasePeer {}

export type OnInvitationReceived = (data: InvitationReceived) => void;

export interface Connected extends BasePeer {}

export type OnConnected = (data: Connected) => void;

export interface Disconnected extends Pick<BasePeer, "peerId"> {}

export type OnDisconnected = (data: Disconnected) => void;

export interface TextReceived extends Pick<BasePeer, "peerId"> {
  text: string;
}

export type OnTextReceived = (data: TextReceived) => void;

export interface FileSource {
  uri: string;
  name?: string;
  mimeType?: string;
}

export type FileTransferDirection = "incoming" | "outgoing";

export type FileTransferStatus =
  | "in_progress"
  | "completed"
  | "cancelled"
  | "failed";

export interface FileTransferUpdate extends Pick<BasePeer, "peerId"> {
  transferId: string;
  direction: FileTransferDirection;
  status: FileTransferStatus;
  bytesTransferred: number;
  totalBytes?: number;
  name?: string;
  mimeType?: string;
  error?: string;
}

export type OnFileTransferUpdate = (data: FileTransferUpdate) => void;

export interface FileReceived extends Pick<BasePeer, "peerId"> {
  transferId: string;
  uri: string;
  name: string;
  mimeType?: string;
  size: number;
}

export type OnFileReceived = (data: FileReceived) => void;
