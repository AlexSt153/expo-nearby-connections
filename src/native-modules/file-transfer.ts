import type { FileSource } from "../types/nearby-connections.types";
import {
  fileReceivedHandler,
  fileTransferUpdateHandler,
  nearbyConnectionsModule,
} from "./nearby-connections-module";

export const sendFile = async (
  targetPeerId: string,
  file: FileSource,
): Promise<string> => {
  return nearbyConnectionsModule.sendFile(
    targetPeerId,
    file.uri,
    file.name,
    file.mimeType,
  );
};

export const cancelFileTransfer = async (
  transferId: string,
): Promise<void> => {
  return nearbyConnectionsModule.cancelFileTransfer(transferId);
};

export const onFileTransferUpdate = fileTransferUpdateHandler.subscribe;
export const onFileReceived = fileReceivedHandler.subscribe;
