# Architecture

The following describes how VPNGate works at runtime on macOS.

## Process model

Two processes split by privilege, talking over XPC:

```mermaid
flowchart LR
    subgraph AppProc["VPNGate.app (user, no root)"]
        UI["SwiftUI MenuBarExtra<br/>server list + filters<br/>connect/disconnect UI<br/>log viewer"]
        HC["HelperClient<br/>(XPC wrapper)"]
        SLS["ServerListStore"]
        UI --> HC
        UI --> SLS
    end

    subgraph HelperProc["VpngateHelper (root, SMAppService daemon)"]
        XPCSvc["HelperXPCService"]
        Sup["OpenVPNSupervisor"]
        XPCSvc --> Sup
    end

    SLS -- "URLSession" --> VG["vpngate.net/api/iphone"]
    HC <-- "NSXPCConnection<br/>(.privileged)" --> XPCSvc
    Sup -- "spawns + manages" --> OVPN["openvpn subprocess (root)"]
```

## Server list

`ServerListStore` fetches the CSV server list from
`vpngate.net/api/iphone/`, and `ServerListDecoder` parses it: strips
the `*vpn_servers` header marker and trailing `*` marker, strips
embedded quotes, then maps each row onto `Server` by column name
(order-independent). The decoded list is cached at
`~/Library/Caches/vpngate/servers.json` with a 24-hour TTL
(`ServerListCache`); a fetch failure keeps whatever's already loaded
and surfaces an error instead of clearing the list.

## The OpenVPN wrapper

`OpenVPNSupervisor` (in `Helper/`) owns one `openvpn` subprocess and
its management-interface connection at a time. Connecting walks
through these steps:

```mermaid
sequenceDiagram
    participant App as VPNGate.app
    participant Sup as OpenVPNSupervisor (helper, root)
    participant OVPN as openvpn subprocess (root)
    participant Mgmt as ManagementClient

    App->>Sup: connect(server) [XPC]
    Sup->>Sup: resolve openvpn path<br/>(bundled, else fallback search paths)
    Sup->>Sup: decode base64 config to temp .ovpn file
    Sup->>Sup: reserve a free loopback port
    Sup->>OVPN: Process.run() with resolved args
    Sup->>Mgmt: connectWithRetry(127.0.0.1, port)
    Mgmt-->>OVPN: TCP dial (retried until openvpn binds)
    Mgmt->>Mgmt: read + discard greeting line
    Mgmt->>OVPN: send "state on"
    OVPN-->>Mgmt: push >STATE:... lines
    Mgmt-->>Sup: onUpdate(state) per line
    Sup-->>App: connectionStateDidChange [XPC callback]
    Note over Mgmt,OVPN: loop until state == CONNECTED
    Sup->>Sup: delete temp .ovpn file
```

## Logging

Persistent logs are appended to `/Library/Application Support/Vpngate/daemon.log`.
