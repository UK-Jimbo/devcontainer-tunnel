# Devcontainer Forward

A Bash script to automatically detect VS Code Dev Containers and set up iptables port forwarding from the host to the container IPs, enabling access to devcontainer services from outside the VM.

## Use Case

When running VS Code in a virtual machine (e.g., on Proxmox) with Dev Containers, the containers' services (like web apps on port 3000) are typically only accessible within the VM. This script allows you to forward those ports to the VM's host IP, making them accessible from external machines, such as your local iMac.

Example setup:
- iMac → Proxmox host → VM (running VS Code + Dev Container) → Forwarded ports accessible from iMac

## Features

- **Automatic Detection**: Scans running Docker containers for VS Code Dev Container metadata and extracts `forwardPorts`.
- **Iptables Management**: Creates and manages dedicated iptables chains for port forwarding.
- **Safety**: Only affects its own rules; preserves existing iptables configurations.
- **Persistence**: Can be installed as a systemd service for automatic setup on boot.
- **Modes**:
  - `--check`: Validate dependencies (iptables, docker, jq).
  - `--dry-run`: Simulate rule generation without applying changes.
  - `--run`: Apply iptables rules for current containers.
  - `--install`: Apply rules and install as a systemd service.
  - `--status`: Show current forwarding status and service state.
  - `--uninstall`: Remove service, rules, and files safely.

## Requirements

- Linux system with `iptables` (most distributions).
- Docker installed and running.
- `jq` for JSON parsing.
- Root privileges (sudo) for iptables and systemd management.

## Installation

1. Clone or download the repository:
   ```bash
   git clone https://github.com/UK-Jimbo/devcontainer-tunnel.git
   cd devcontainer-tunnel
   ```

2. Make the script executable:
   ```bash
   chmod +x devcontainer-forward.sh
   ```

## Usage

Run as root (sudo) in the directory containing the script.

### Check Dependencies
```bash
sudo ./devcontainer-forward.sh --check
```

### Dry Run (Safe Simulation)
```bash
sudo ./devcontainer-forward.sh --dry-run
```

### Apply Rules
```bash
sudo ./devcontainer-forward.sh --run
```

### Install as Service (Persistent)
```bash
sudo ./devcontainer-forward.sh --install
```

### Check Status
```bash
sudo ./devcontainer-forward.sh --status
```

### Uninstall
```bash
sudo ./devcontainer-forward.sh --uninstall
```

## Example Output

After running `--run` with a devcontainer forwarding ports 3000-3003:

```
Rules applied successfully:
[
  {
    "container_id": "abc123...",
    "container_name": "my-devcontainer",
    "target": "172.17.0.2:3000",
    "port": 3000,
    "proto": "tcp",
    "url": "http://192.168.1.21:3000"
  },
  ...
]
```

You can then access `http://<VM_IP>:3000` from your external machine.

## How It Works

1. Detects running containers with Dev Container labels.
2. Parses `devcontainer.metadata` for `forwardPorts`.
3. Creates iptables NAT rules to DNAT incoming traffic on host ports to container IPs.
4. Adds ACCEPT rules in the FORWARD chain for the traffic.
5. Stores state in `/var/lib/devcontainer-forward/state.json`.

## Logs

Activity is logged to `/var/log/devcontainer-forward.log`.

## Safety Notes

- The script only manages its own iptables chains (`DEVCONTAINER_FWD_NAT`, `DEVCONTAINER_FWD_FILTER`).
- `--uninstall` safely removes only what the script created.
- Re-running `--run` clears old rules before applying new ones.
