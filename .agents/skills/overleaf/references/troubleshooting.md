# Overleaf Community Edition Troubleshooting Guide

This guide covers common issues, error messages, and solutions when building and running Overleaf Community Edition on Podman.

---

## 1. MongoDB Replica Set Errors

### Symptom:
Container logs show:
```text
MongoServerError: Transaction numbers are only allowed on a replica set member or mongos
```
or
```text
MongoError: no replSet args query ??
```

### Cause:
Overleaf v4.0+ uses MongoDB multi-document transactions to guarantee project consistency. MongoDB transactions only function when MongoDB is running as an initiated replica set.

### Solution:
1. Ensure the MongoDB container was started with the `--replSet overleaf` argument:
   ```bash
   podman exec overleaf-mongo mongod --version
   ```
2. Run the initialization script:
   ```bash
   ./scripts/init-replica-set.sh overleaf-mongo overleaf 127.0.0.1:27017
   ```
3. Or initialize manually via MongoDB shell:
   ```bash
   podman exec -it overleaf-mongo mongosh --eval 'rs.initiate({_id: "overleaf", members: [{_id: 0, host: "127.0.0.1:27017"}]})'
   ```

---

## 2. Port Endpoint Issues

### Symptom:
```text
Error: bind: address already in use
```
or
```text
permission denied (rootless port binding below 1024)
```

### Cause:
- Another service is occupying the target port (e.g., port 80 or 8080).
- Rootless Podman cannot bind to privileged ports below 1024 by default on Linux without `sysctl net.ipv4.ip_unprivileged_port_start=80`.

### Solution:
- Use an unprivileged port (1024-65535), such as `8080`, `8000`, or `8888`:
  ```bash
  ./scripts/overleaf-ctl.sh up --port 8080
  ```
- Check what process is using the port:
  ```bash
  lsof -i :8080  # macOS / Linux
  ```

---

## 3. LaTeX Compilation Errors in Documents

### Symptom:
When compiling a LaTeX project in the Overleaf web UI:
- `! LaTeX Error: File 'tikz.sty' not found.`
- `sh: 1: latexmk: not found`
- `Package minted Error: You must have 'pygmentize' installed to use this package.`

### Cause:
The default base image contains a basic TeX Live installation to keep the initial download size moderate. Full packages and utility tools must be installed.

### Solutions:

#### Option A: Install packages dynamically in the running container (Instant)
```bash
./scripts/overleaf-ctl.sh install-pkg latexmk biber collection-latexextra collection-mathscience
```

#### Option B: Build a custom image with complete TeX Live (Recommended for production)
```bash
# Build custom image with complete package catalog
./scripts/overleaf-ctl.sh build --full --tag overleaf-full:latest

# Run the stack using your built image
./scripts/overleaf-ctl.sh up --port 8080 --image overleaf-full:latest
```

---

## 4. Admin Account & Setup Wizard

### Accessing the Web Wizard:
Visit `http://localhost:<PORT>/launchpad` in your browser. This setup wizard appears on fresh installations to register the initial administrator.

### Generating Admin Account via CLI:
If the web wizard was already completed or inaccessible:
```bash
./scripts/overleaf-ctl.sh create-admin --email admin@example.com
```
This prints an activation link (e.g., `http://localhost:8080/user/password/set?passwordResetToken=...`). Paste that link into your browser to choose a password.

---

## 5. Storage & Permission Errors (SELinux / Host Volumes)

### Symptom:
```text
Permission denied: /var/lib/overleaf/data
```

### Cause:
On SELinux-enforcing systems (Fedora, RHEL, CentOS), containers cannot access volume mounts without the `:Z` shared label.

### Solution:
All scripts in this skill use named Podman volumes with the `:Z` flag (`-v overleaf_data:/var/lib/overleaf:Z`), which handles labeling automatically. If you mount host paths directly, append `:Z`:
```bash
-v /path/on/host/overleaf-data:/var/lib/overleaf:Z
```

---

## 6. Container Memory & Disk Constraints

### Minimum Recommended Resources:
- **RAM**: 4 GB minimum (8 GB recommended for heavy LaTeX compiles with XeLaTeX/LuaLaTeX or large graphics).
- **Disk**: 15 GB minimum (25+ GB if installing `scheme-full` TeX Live).

### Inspecting Podman Resources:
```bash
podman system df
podman stats
```
If running Podman inside a VM (macOS/Windows), ensure the VM has sufficient memory allocated:
```bash
podman machine stop
podman machine set --memory 8192 --cpus 4
podman machine start
```
