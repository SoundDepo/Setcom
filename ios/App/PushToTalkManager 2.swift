import Foundation
import PushToTalk
import AVFoundation

@available(iOS 16.0, *)
class PushToTalkManager: NSObject, PTChannelManagerDelegate, PTChannelRestorationDelegate {
    static let shared = PushToTalkManager()

    private var channelManager: PTChannelManager?
    private(set) var channelUUID: UUID?

    private(set) var sessionName    = ""
    private(set) var sessionRole    = ""
    private(set) var sessionChannel = ""

    func setup() {
        PTChannelManager.channelManager(delegate: self, restorationDelegate: self) { [weak self] manager, error in
            if let error = error {
                print("[PTT] Manager init failed: \(error)")
                return
            }
            self?.channelManager = manager
            print("[PTT] Manager ready")
        }
    }

    func setSession(name: String, role: String, channel: String) {
        sessionName    = name
        sessionRole    = role
        sessionChannel = channel
        joinChannel()
    }

    func beginTransmitting() {
        guard let manager = channelManager, let uuid = channelUUID else { return }
        manager.requestBeginTransmitting(channelUUID: uuid)
    }

    func endTransmitting() {
        guard let manager = channelManager, let uuid = channelUUID else { return }
        manager.stopTransmitting(channelUUID: uuid)
    }

    func setActiveSpeaker(_ name: String?) {
        guard let manager = channelManager, let uuid = channelUUID else { return }
        let participant = name.map { PTParticipant(name: $0, image: nil) }
        manager.setActiveRemoteParticipant(participant, channelUUID: uuid, completionHandler: nil)
    }

    // MARK: - Private

    private func joinChannel() {
        guard !sessionName.isEmpty, let manager = channelManager else { return }
        guard channelUUID == nil else { return }
        let uuid = UUID()
        channelUUID = uuid
        manager.requestJoinChannel(
            channelUUID: uuid,
            descriptor: PTChannelDescriptor(name: sessionChannel.uppercased(), image: nil)
        )
        print("[PTT] Joining \(sessionChannel.uppercased())")
    }

    // MARK: - PTChannelManagerDelegate

    func channelManager(_ channelManager: PTChannelManager,
                        didJoinChannel channelUUID: UUID,
                        reason: PTChannelJoinReason) {
        print("[PTT] Joined reason=\(reason.rawValue)")
    }

    func channelManager(_ channelManager: PTChannelManager,
                        didLeaveChannel channelUUID: UUID,
                        reason: PTChannelLeaveReason) {
        print("[PTT] Left reason=\(reason.rawValue)")
        if self.channelUUID == channelUUID {
            self.channelUUID = nil
            if !sessionName.isEmpty && reason != .userRequest {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.joinChannel()
                }
            }
        }
    }

    func channelManager(_ channelManager: PTChannelManager,
                        failedToJoinChannel channelUUID: UUID,
                        error: Error) {
        print("[PTT] Failed to join: \(error.localizedDescription)")
        self.channelUUID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.joinChannel()
        }
    }

    func channelManager(_ channelManager: PTChannelManager,
                        failedToBeginTransmittingInChannel channelUUID: UUID,
                        error: Error) {
        print("[PTT] Failed to begin TX: \(error.localizedDescription)")
    }

    func channelManager(_ channelManager: PTChannelManager,
                        failedToStopTransmittingInChannel channelUUID: UUID,
                        error: Error) {
        print("[PTT] Failed to stop TX: \(error.localizedDescription)")
    }

    func channelManager(_ channelManager: PTChannelManager,
                        channelUUID: UUID,
                        didBeginTransmittingFrom source: PTChannelTransmitRequestSource) {
        print("[PTT] Began TX source=\(source.rawValue)")
        NativeAudioManager.shared.startPTT(channel: sessionChannel)
        WatchSessionManager.shared.notifyJSPTTState(active: true)
    }

    func channelManager(_ channelManager: PTChannelManager,
                        channelUUID: UUID,
                        didEndTransmittingFrom source: PTChannelTransmitRequestSource) {
        print("[PTT] Ended TX")
        NativeAudioManager.shared.stopPTT()
        WatchSessionManager.shared.notifyJSPTTState(active: false)
    }

    func channelManager(_ channelManager: PTChannelManager,
                        receivedEphemeralPushToken pushToken: Data) {
        let hex = pushToken.map { String(format: "%02x", $0) }.joined()
        print("[PTT] Push token updated")
        WatchSessionManager.shared.sendPTTPushToken(hex)
    }

    func incomingPushResult(channelManager: PTChannelManager,
                            channelUUID: UUID,
                            pushPayload: [String: Any]) -> PTPushResult {
        guard let speaker = pushPayload["speaker"] as? String, !speaker.isEmpty else {
            return .leaveChannel
        }
        return .activeRemoteParticipant(PTParticipant(name: speaker, image: nil))
    }

    // Framework owns the audio session — do NOT call setActive here
    func channelManager(_ channelManager: PTChannelManager,
                        didActivate audioSession: AVAudioSession) {
        print("[PTT] Audio session activated")
        NativeAudioManager.shared.startVoiceIOForPTT()
    }

    func channelManager(_ channelManager: PTChannelManager,
                        didDeactivate audioSession: AVAudioSession) {
        print("[PTT] Audio session deactivated")
        NativeAudioManager.shared.stopVoiceIO()
    }

    // MARK: - PTChannelRestorationDelegate

    func channelDescriptor(restoredChannelUUID: UUID) -> PTChannelDescriptor {
        return PTChannelDescriptor(name: sessionChannel.uppercased(), image: nil)
    }
}
