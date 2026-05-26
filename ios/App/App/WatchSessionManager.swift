import WatchConnectivity
import UIKit
import WebKit
import Capacitor
import UserNotifications

class WatchSessionManager: NSObject, WCSessionDelegate, WKScriptMessageHandler {
    static let shared = WatchSessionManager()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    var pendingVoIPToken: String?

    func registerBridge() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            let vc = scene?.windows.first?.rootViewController as? CAPBridgeViewController
            print("[Bridge] vc=\(vc != nil ? "found" : "NIL"), webView=\(vc?.bridge?.webView != nil ? "found" : "NIL")")
            guard let webView = vc?.bridge?.webView else { return }
            webView.configuration.userContentController.add(self, name: "setcomBridge")
            print("[Bridge] setcomBridge registered")
            if let token = self.pendingVoIPToken {
                webView.evaluateJavaScript(
                    "if(typeof receiveVoIPToken==='function')receiveVoIPToken('\(token)');",
                    completionHandler: nil)
            }
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
            print("[NOTIF] page-alert via bridge: \(name) ch=\(channel)")
            forwardPageAlert(name: name, channel: channel)
            scheduleCallNotification(caller: name, channel: channel)
        case "session-info":
            let name    = body["name"]    as? String ?? ""
            let role    = body["role"]    as? String ?? ""
            let channel = body["channel"] as? String ?? ""
            guard !name.isEmpty else { return }
            UserDefaults.standard.set(name,    forKey: "sc_name")
            UserDefaults.standard.set(channel, forKey: "sc_channel")
            sendToWatch(["type": "session-info", "name": name, "role": role, "channel": channel])
            NativeAudioManager.shared.setSession(name: name, role: role, channel: channel)
            if let token = pendingVoIPToken { registerTokenWithServer(voipToken: token) }
        case "ptt-direct-begin":
            let channel = body["channel"] as? String ?? NativeAudioManager.shared.sessionChannel
            NativeAudioManager.shared.startTransmit(channel: channel)
        case "ptt-direct-end":
            NativeAudioManager.shared.stopTransmit()
        case "ptt-active-speaker":
            // Forward real-time active speaker to Watch for haptics + display
            let name = body["name"] as? String ?? ""
            sendRealtimeToWatch(["type": "ptt-active-speaker", "name": name])
        default:
            break
        }
    }

    func forwardPageAlert(name: String, channel: String) {
        let state = WCSession.default.activationState.rawValue
        let reachable = WCSession.default.isReachable
        print("[Watch] forwardPageAlert activated=\(state==2) reachable=\(reachable) name=\(name)")
        sendToWatch(["type": "page-alert", "name": name, "channel": channel])
    }

    func sendPushToken(_ token: String) {
        evalJS("if(typeof receivePushToken==='function')receivePushToken('\(token)');")
        NativeAudioManager.shared.setPushToken(token)
    }

    func registerVoIPToken(_ token: String) {
        pendingVoIPToken = token
        evalJS("if(typeof receiveVoIPToken==='function')receiveVoIPToken('\(token)');")
        NativeAudioManager.shared.setVoIPToken(token)
        registerTokenWithServer(voipToken: token)
    }

    func registerTokenWithServer(voipToken: String) {
        let name    = UserDefaults.standard.string(forKey: "sc_name")    ?? ""
        let channel = UserDefaults.standard.string(forKey: "sc_channel") ?? ""
        guard !name.isEmpty,
              let url = URL(string: "https://setcom-production.up.railway.app/api/register-token") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "name": name, "voipToken": voipToken, "channel": channel
        ])
        URLSession.shared.dataTask(with: req).resume()
    }

    func scheduleCallNotification(caller: String, channel: String) {
        let labels: [String: String] = [
            "sound": "Sound Dept", "camera": "Camera", "director": "Director",
            "ad": "AD / Prod", "ge": "Grip / Elec", "hmu": "Hair & Makeup",
            "pa": "PA Channel", "all": "All Channels"
        ]
        let label = labels[channel] ?? channel.uppercased()
        let content = UNMutableNotificationContent()
        content.title = "📞 SETCOM CALL"
        content.body  = "\(caller) · \(label)"
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "setcom-incoming-call", content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false))
        print("[NOTIF] scheduling: delegate=\(String(describing: UNUserNotificationCenter.current().delegate))")
        UNUserNotificationCenter.current().add(req) { error in
            print(error.map { "[NOTIF] error: \($0)" } ?? "[NOTIF] added OK")
        }
    }

    func handoffToNative() {
        evalJS("if(typeof nativeAudioHandoff==='function')nativeAudioHandoff();")
    }

    func handoffFromNative() {
        evalJS("if(typeof webRTCHandback==='function')webRTCHandback();")
    }

    private func sendToWatch(_ msg: [String: Any]) {
        guard WCSession.default.activationState == .activated else {
            print("[Watch] sendToWatch blocked — session not activated")
            return
        }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(msg, replyHandler: nil, errorHandler: { err in
                print("[Watch] sendMessage error: \(err.localizedDescription)")
            })
        }
        do {
            try WCSession.default.updateApplicationContext(msg)
            print("[Watch] applicationContext sent")
        } catch {
            print("[Watch] applicationContext error: \(error.localizedDescription)")
        }
    }

    // Real-time only — no applicationContext persistence needed
    private func sendRealtimeToWatch(_ msg: [String: Any]) {
        guard WCSession.default.activationState == .activated,
              WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(msg, replyHandler: nil, errorHandler: nil)
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
            NativeAudioManager.shared.startTransmit(channel: NativeAudioManager.shared.sessionChannel)
        case "ptt-stop":
            NativeAudioManager.shared.stopTransmit()
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
