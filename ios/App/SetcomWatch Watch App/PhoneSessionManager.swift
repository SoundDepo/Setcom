import WatchConnectivity
import WatchKit

class PhoneSessionManager: NSObject, WCSessionDelegate, ObservableObject {
    static let shared = PhoneSessionManager()

    @Published var channel       = ""
    @Published var sessionName   = ""
    @Published var activeSpeaker: String? = nil
    @Published var isTransmitting = false
    @Published var isSessionActive = false

    private var hapticAlternate = false
    private var hapticTimer: Timer?

    func activate() {
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - PTT

    func startPTT() {
        guard !isTransmitting else { return }
        isTransmitting = true
        WKInterfaceDevice.current().play(.start)
        send(["type": "ptt-start"])
    }

    func stopPTT() {
        guard isTransmitting else { return }
        isTransmitting = false
        WKInterfaceDevice.current().play(.stop)
        send(["type": "ptt-stop"])
    }

    // MARK: - WCSession send

    private func send(_ msg: [String: Any]) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(msg, replyHandler: nil, errorHandler: nil)
    }

    // MARK: - Incoming messages from iPhone

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        handle(context)
    }

    private func handle(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }
        DispatchQueue.main.async {
            switch type {
            case "session-info":
                self.sessionName    = msg["name"]    as? String ?? ""
                self.channel        = msg["channel"]  as? String ?? ""
                self.isSessionActive = !self.sessionName.isEmpty

            case "ptt-active-speaker":
                let name = msg["name"] as? String
                let incoming = (name?.isEmpty == false) ? name : nil
                let wasNil = self.activeSpeaker == nil
                self.activeSpeaker = incoming
                if wasNil && incoming != nil { self.pulseIncoming() }
                if incoming == nil { self.stopHaptics() }

            case "page-alert":
                self.pulseIncoming()

            default:
                break
            }
        }
    }

    // MARK: - Haptics

    private func pulseIncoming() {
        stopHaptics()
        fireHaptic()
        hapticTimer = Timer.scheduledTimer(withTimeInterval: 0.13, repeats: true) { [weak self] _ in
            self?.fireHaptic()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) { [weak self] in
            self?.stopHaptics()
        }
    }

    private func stopHaptics() {
        hapticTimer?.invalidate()
        hapticTimer = nil
    }

    private func fireHaptic() {
        WKInterfaceDevice.current().play(hapticAlternate ? .notification : .failure)
        hapticAlternate.toggle()
    }

    // MARK: - WCSessionDelegate stubs

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}
}
