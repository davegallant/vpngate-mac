import Foundation
import VpngateShared

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    // One shared service for the daemon's whole lifetime -- creating a new
    // HelperXPCService (and therefore a new OpenVPNSupervisor) per incoming
    // connection reset all connection state, including an in-progress or
    // already-established VPN tunnel, every time the app reconnected.
    private let service = HelperXPCService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        service.connection = newConnection
        newConnection.exportedInterface = NSXPCInterface(with: VpngateHelperXPCProtocol.self)
        newConnection.exportedObject = service
        newConnection.remoteObjectInterface = NSXPCInterface(with: VpngateHelperClientXPCProtocol.self)
        newConnection.resume()
        return true
    }
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: VpngateIdentifiers.helperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
