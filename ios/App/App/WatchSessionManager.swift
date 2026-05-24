import WatchConnectivity
import UIKit
import WebKit
import Capacitor

class WatchSessionManager: NSObject, WCSessionDelegate, WKScriptMessageHandler {
    static let shared = WatchSessionManager()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func registerBridge() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            let vc = scene?.windows.first?.rootViewController as? CAPBridgeViewController
            vc?.bridge?.webView?.configuration.userContentController.add(self, name: "setcomBridge")
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "setcomBridge",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "page-alert":
            let name    = body["name"]    as? String ?? "Someone"
            let channel = body["channel"] as? String ?? ""
            sendToWatch(["type": "page-alert", "name": name, "channel": channel])
        case "session-info":
            let name    = body["name"]    as? String ?? ""
            let role    = body["role"]    as? String ?? ""
            let channel = body["channel"] as? String ?? ""
            guard !name.isEmpty else { return }
            sendToWatch(["type": "session-info", "name": name, "role": role, "channel": channel])
            NativeAudioManager.shared.setSession(name: name, role: role, channel: channel)
            if #available(iOS 16.0, *) {
                PushToTalkManager.shared.setSession(name: name, role: role, channel: channel)
            }
        case "ptt-begin":
            if #available(iOS 16.0, *) { PushToTalkManager.shared.beginTransmitting() }
        case "ptt-end":
            if #available(iOS 16.0, *) { PushToTalkManager.shared.endTransmitting() }
        case "ptt-active-speaker":
            let speaker = body["name"] as? String
            if #available(iOS 16.0, *) { PushToTalkManager.shared.setActiveSpeaker(speaker) }
            sendToWatch(["type": "ptt-active-speaker", "name": speaker ?? ""])
        default:
            break
        }
    }

    // MARK: - Helpers called by PushToTalkManager

    func notifyJSPTTState(active: Bool) {
        let fn = active ? "onNativePTTBegin" : "onNativePTTEnd"
        evalJS("if(typeof \(fn)==='function')\(fn)();")
    }

    func sendPTTPushToken(_ token: String) {
        evalJS("if(typeof receivePTTPushToken==='function')receivePTTPushToken('\(token)');")
    }

    func forwardPageAlert(name: String, channel: String) {
        sendToWatch(["type": "page-alert", "name": name, "channel": channel])
    }

    func registerVoIPToken(_ token: String) {
        evalJS("if(typeof receiveVoIPToken==='function')receiveVoIPToken('\(token)');")
    }

    func handoffToNative() {
        evalJS("if(typeof nativeAudioHandoff==='function')nativeAudioHandoff();")
    }

    func handoffFromNative() {
        evalJS("if(typeof webRTCHandback==='function')webRTCHandback();")
    }

    private func sendToWatch(_ msg: [String: Any]) {
        guard WCSession.default.activationState == .activated else { return }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(msg, replyHandler: nil, errorHandler: nil)
        }
        try? WCSession.default.updateApplicationContext(msg)
    }

    func evalJS(_ js: String) {
        DispatchQueue.main.async {
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            let vc = scene?.windows.first?.rootViewController as? CAPBridgeViewController
            vc?.bridge?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // Watch → iPhone PTT signals
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        switch type {
        case "ptt-start":
            if #available(iOS 16.0, *) { PushToTalkManager.shared.beginTransmitting() }
        case "ptt-stop":
            if #available(iOS 16.0, *) { PushToTalkManager.shared.endTransmitting() }
        default:
            break
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}
