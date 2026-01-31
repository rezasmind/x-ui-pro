Got it — you want a **clean PRD-style prompt** you can hand directly to another LLM so it can implement **5 Psiphon client instances** on Ubuntu with fixed countries and ports.

Below is a **copy-paste PRD**, written for an engineering LLM. No fluff, very explicit, production-oriented.

---

## Product Requirements Document (PRD)

### Title

Multi-Instance Psiphon Client Deployment on Ubuntu Server

### Objective

Deploy **5 concurrent Psiphon client instances** on a single Ubuntu server.
Each instance must:

* Run independently
* Listen on **unique local proxy ports**
* Prefer a **specific egress country**
* Start automatically on boot
* Be observable and restart on failure

### Target Environment

* OS: Ubuntu Server 20.04+
* Architecture: x86_64
* Network: outbound internet access available
* Privileges: root or sudo access

---

## Functional Requirements

### 1. Psiphon Client

* Use the **official Psiphon tunnel-core Linux client** (binary or ConsoleClient).
* No GUI components.
* Each instance runs as its **own process**.

---

### 2. Instances & Countries

Create **exactly 5 instances**, each with a fixed egress region:

| Instance Name | Country     | EgressRegion |
| ------------- | ----------- | ------------ |
| psiphon-us    | USA         | `US`         |
| psiphon-gb    | UK          | `GB`         |
| psiphon-fr    | France      | `FR`         |
| psiphon-sg    | Singapore   | `SG`         |
| psiphon-nl    | Netherlands | `NL`         |

---

### 3. Local Proxy Ports

Each instance must expose **both SOCKS5 and HTTP proxies**, bound to `127.0.0.1`, with **no port conflicts**.

| Instance | HTTP Port | SOCKS Port |
| -------- | --------- | ---------- |
| US       | 8081      | 1081       |
| GB       | 8082      | 1082       |
| FR       | 8083      | 1083       |
| SG       | 8084      | 1084       |
| NL       | 8085      | 1085       |

---

### 4. Configuration Files

* Each instance must have its **own directory**:

  ```
  /opt/psiphon/
    ├── psiphon-us/
    ├── psiphon-gb/
    ├── psiphon-fr/
    ├── psiphon-sg/
    └── psiphon-nl/
  ```
* Each directory must contain:

  * `psiphon-client` binary
  * `client.json` config file

#### Required `client.json` fields

```json
{
  "LocalHttpProxyPort": <PORT>,
  "LocalSocksProxyPort": <PORT>,
  "EgressRegion": "<COUNTRY_CODE>",
  "PropagationChannelId": "FFFFFFFFFFFFFFFF"
}
```

---

### 5. Process Management

* Use **systemd**.
* Implement **one systemd template unit** (`psiphon@.service`).
* Each instance must be started via:

  ```
  systemctl enable --now psiphon@psiphon-us
  ```
* Requirements:

  * Auto-restart on failure
  * Start after network is online
  * Logs available via `journalctl`

---

### 6. Security & Stability

* Run under a **non-root user** (e.g. `psiphon`).
* Increase `NOFILE` limit to ≥ 65536.
* Proxies must bind to `127.0.0.1` only (no public exposure).
* No port reuse between instances.

---

### 7. Validation & Testing

The implementation is complete when:

* `systemctl status psiphon@psiphon-us` shows **active (running)** for all 5 instances
* `ss -tulpn` shows all 10 proxy ports listening
* Running:

  ```
  curl --socks5-hostname 127.0.0.1:1081 https://ifconfig.co
  ```

  returns an IP geolocated to **United States**, and similarly for each instance’s country.

---

### Non-Goals

* No Psiphon server deployment
* No traffic encryption beyond Psiphon defaults
* No public proxy exposure
* No GUI or desktop usage

---

### Deliverables Expected from the LLM

1. Directory structure creation commands
2. All 5 `client.json` files
3. `psiphon@.service` systemd unit file
4. Commands to enable, start, and verify all instances
5. Basic troubleshooting commands

---

If you want, I can also:

* Convert this into a **single executable bash installer**
* Add **external port forwarding** (firewall-restricted)
* Add **health-check + auto-restart monitoring**
* Tune for **high concurrency / production load**

Just say the word.
