import {
  FileReceived,
  FileTransferUpdate,
  onFileReceived,
  onFileTransferUpdate,
} from "expo-nearby-connections";
import { useEffect, useState } from "react";

export function useFileTransferListener(peerId: string) {
  const [transfers, setTransfers] = useState<FileTransferUpdate[]>([]);
  const [receivedFiles, setReceivedFiles] = useState<FileReceived[]>([]);

  useEffect(() => {
    const unsubscribeUpdate = onFileTransferUpdate((update) => {
      if (update.peerId !== peerId) {
        return;
      }

      setTransfers((current) => {
        const next = current.filter(
          (transfer) => transfer.transferId !== update.transferId,
        );
        return [update, ...next].slice(0, 5);
      });
    });

    const unsubscribeReceived = onFileReceived((file) => {
      if (file.peerId !== peerId) {
        return;
      }
      setReceivedFiles((current) => [file, ...current].slice(0, 5));
    });

    return () => {
      unsubscribeUpdate();
      unsubscribeReceived();
    };
  }, [peerId]);

  return { transfers, receivedFiles };
}
