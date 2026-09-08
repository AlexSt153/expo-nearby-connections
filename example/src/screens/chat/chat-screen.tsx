import * as DocumentPicker from "expo-document-picker";
import {
  cancelFileTransfer,
  disconnect,
  sendFile,
  sendText,
} from "expo-nearby-connections";
import React, { useCallback, useEffect } from "react";
import { Alert, StyleSheet, Text, TouchableOpacity, View } from "react-native";
import { GiftedChat, IMessage } from "react-native-gifted-chat";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { Header } from "../../components/header";
import { colors } from "../../constants/color";
import { useFileTransferListener } from "../../hooks/use-file-transfer-listener";
import { useParam } from "../../hooks/use-param";
import { usePayloadListener } from "../../hooks/use-payload-listener";

interface Props {}

export const ChatScreen: React.FC<Props> = () => {
  const param = useParam<"chat">();
  const myDevice = param.params.myDevice;
  const targetDevice = param.params.targetDevice;
  const insets = useSafeAreaInsets();
  const { data, setData } = usePayloadListener(targetDevice);
  const { transfers, receivedFiles } = useFileTransferListener(
    targetDevice.peerId,
  );

  useEffect(() => {
    return () => {
      disconnect(targetDevice.peerId).catch(() => {});
    };
  }, [targetDevice.peerId]);

  const handleSendText = useCallback(
    (messages: IMessage[]) => {
      sendText(targetDevice.peerId, messages[0].text)
        .then(() => {
          setData((previousMessages) =>
            GiftedChat.append(previousMessages, messages)
          );
        })
        .catch(() => {});
    },
    [setData, targetDevice.peerId]
  );

  const handleSendFile = useCallback(async () => {
    const result = await DocumentPicker.getDocumentAsync({
      copyToCacheDirectory: true,
    });
    if (result.canceled) {
      return;
    }

    const file = result.assets[0];
    try {
      await sendFile(targetDevice.peerId, {
        uri: file.uri,
        name: file.name,
        mimeType: file.mimeType,
      });
    } catch (error) {
      Alert.alert(
        "Unable to send file",
        error instanceof Error ? error.message : String(error),
      );
    }
  }, [targetDevice.peerId]);

  const handleCancelTransfer = useCallback(async (transferId: string) => {
    try {
      await cancelFileTransfer(transferId);
    } catch (error) {
      Alert.alert(
        "Unable to cancel transfer",
        error instanceof Error ? error.message : String(error),
      );
    }
  }, []);

  return (
    <View style={[styles.container, { paddingBottom: insets.bottom }]}>
      <Header>Chat</Header>

      <TouchableOpacity style={styles.fileButton} onPress={handleSendFile}>
        <Text style={styles.fileButtonText}>Send file</Text>
      </TouchableOpacity>

      {transfers.map((transfer) => {
        const percent = transfer.totalBytes
          ? Math.round((transfer.bytesTransferred / transfer.totalBytes) * 100)
          : undefined;
        return (
          <TouchableOpacity
            key={transfer.transferId}
            disabled={transfer.status !== "in_progress"}
            onPress={() => handleCancelTransfer(transfer.transferId)}
            style={styles.transferRow}
          >
            <Text numberOfLines={1} style={styles.transferText}>
              {transfer.direction === "incoming" ? "Receiving" : "Sending"}{" "}
              {transfer.name ?? transfer.transferId}: {transfer.status}
              {percent !== undefined ? ` (${percent}%)` : ""}
            </Text>
            {transfer.status === "in_progress" ? (
              <Text style={styles.cancelText}>Cancel</Text>
            ) : null}
          </TouchableOpacity>
        );
      })}

      {receivedFiles.slice(0, 1).map((file) => (
        <Text key={file.transferId} numberOfLines={1} style={styles.receivedText}>
          Received {file.name}: {file.uri}
        </Text>
      ))}

      <GiftedChat
        alwaysShowSend={true}
        messages={data}
        onSend={handleSendText}
        user={{ _id: myDevice.peerId, name: myDevice.name }}
        textInputProps={{
          autoCorrect: false,
        }}
      />
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.white,
  },
  fileButton: {
    marginHorizontal: 16,
    marginTop: 8,
    padding: 10,
    borderRadius: 4,
    backgroundColor: colors.primary,
    alignItems: "center",
  },
  fileButtonText: {
    color: colors.white,
    fontWeight: "bold",
  },
  transferRow: {
    flexDirection: "row",
    gap: 8,
    marginHorizontal: 16,
    paddingVertical: 6,
  },
  transferText: {
    flex: 1,
    color: colors.greenDarker,
  },
  cancelText: {
    color: colors.primary,
    fontWeight: "bold",
  },
  receivedText: {
    marginHorizontal: 16,
    paddingBottom: 4,
    color: colors.greenDarker,
  },
});
