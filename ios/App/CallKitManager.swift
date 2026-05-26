import CallKit
import AVFoundation

class CallKitManager: NSObject, CXProviderDelegate {
    static let shared = CallKitManager()

    private let provider: CXProvider
    private let callController = CXCallController()
    private(set) var activeCallUUID: UUID?

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = false
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    // Reports a PTT transmission or page as an incoming call (required by iOS 13+ for VoIP push).
    // Auto-answers immediately so no user interaction is needed.
    func reportIncoming(from name: String, channel: String) {
        let uuid = UUID()
        activeCallUUID = uuid
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = "\(name) · \(channel)"
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false

        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            guard error == nil, let uuid = self?.activeCallUUID else { return }
            let answer = CXAnswerCallAction(call: uuid)
            self?.callController.requestTransaction(with: [answer]) { _ in }
        }
    }

    func endCurrentCall() {
        guard let uuid = activeCallUUID else { return }
        provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
        activeCallUUID = nil
    }

    // MARK: - CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        NativeAudioManager.shared.stopTransmit()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat,
                                 options: [.allowBluetooth, .defaultToSpeaker])
        try? session.setActive(true)
        NativeAudioManager.shared.ensureConnected()
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        NativeAudioManager.shared.stopTransmit()
        activeCallUUID = nil
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        NativeAudioManager.shared.ensureConnected()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}
