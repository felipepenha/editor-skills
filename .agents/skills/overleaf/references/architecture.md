# Overleaf Community Edition Architecture & Podman Runtime

This document describes the component architecture, networking, persistence, and cross-platform design of Overleaf Community Edition (ShareLaTeX) running on Podman.

---

## 1. Component Architecture

Overleaf Community Edition comprises three core services:

```text
               +--------------------------------------------------+
               |                  Host Machine                    |
               |                                                  |
               |  HTTP Request -> Host Port (e.g. 8080)           |
               +-----------------------+--------------------------+
                                       |
+--------------------------------------v---------------------------------------+
| Podman Pod: overleaf-pod                                                     |
| (Shared Network Namespace: localhost / 127.0.0.1)                             |
|                                                                              |
|  +------------------------------+     +-----------------------------------+  |
|  | Container: overleaf-server   |     | Container: overleaf-mongo         |  |
|  | (sharelatex/sharelatex)      |     | (mongo:6.0 or mongo:5.0)          |  |
|  |                              |     |                                   |  |
|  | - Web UI & Express HTTP (:80)|     | - Port 27017                      |  |
|  | - Real-time Doc Updater      +---->| - WiredTiger Storage Engine       |  |
|  | - CLSI (LaTeX Compiler)      |     | - Replica Set: "overleaf"         |  |
|  | - Notifications Service      |     +-----------------+-----------------+  |
|  +--------------+---------------+                       |                    |
|                 |                                       |                    |
|                 v                                       |                    |
|  +------------------------------+                       |                    |
|  | Container: overleaf-redis    |                       |                    |
|  | (redis:7-alpine)             |                       |                    |
|  |                              |                       |                    |
|  | - Port 6379                  |                       |                    |
|  | - Pub/Sub & Session Cache    |                       |                    |
|  +------------------------------+                       |                    |
+---------------------------------------------------------+--------------------+
                               |                          |
                               v                          v
                     +-------------------+      +-------------------+
                     | Volume:           |      | Volume:           |
                     | overleaf_data     |      | overleaf_mongo... |
                     +-------------------+      +-------------------+
```

### Services Description

1. **Overleaf Server (`sharelatex/sharelatex`)**:
   - Runs the web application frontend, backend services (Node.js), document updater, project history, and the Command Line Service Interface (CLSI) for compiling LaTeX documents.
   - Internal port: `80`.
   - Storage path: `/var/lib/overleaf` (project files, user templates, cache, compiled outputs).

2. **MongoDB Database (`mongo:8.0`)**:
   - Stores user accounts, project metadata, document structures, collaboration permissions, and project settings.
   - **Crucial Requirement**: Overleaf v5+ requires MongoDB >= 8.0 and transactions for data consistency. MongoDB requires a configured **replica set** (e.g., `--replSet overleaf`) and an executed `rs.initiate()` before transactions can succeed. Standalone MongoDB instances will cause Overleaf startup crashes.

3. **Redis (`redis:7-alpine` / `redis:6-alpine`)**:
   - Fast in-memory key-value store used for session tokens, real-time socket connections, operational transform queues, and inter-service messaging.

---

## 2. Podman Deployment Topologies

### Topology A: Podman Pod (Recommended)
- All three containers share the exact same network namespace (`localhost`).
- **Advantages**:
  - Zero inter-container DNS resolution issues.
  - Overleaf communicates with Mongo at `mongodb://127.0.0.1:27017/sharelatex` and Redis at `127.0.0.1:6379`.
  - Single point of port publishing: `podman pod create -p 8080:80`.
  - Stack-wide lifecycle control: `podman pod stop`, `podman pod start`, `podman pod rm`.

### Topology B: Podman User-Defined Network
- Containers run independently on a bridge network (e.g., `overleaf-net`).
- Containers resolve each other via internal DNS names (`overleaf-mongo`, `overleaf-redis`).
- Overleaf connects via `mongodb://overleaf-mongo:27017/sharelatex` and `overleaf-redis:6379`.

---

## 3. Architecture & OS Independence

This skill and its accompanying tools are designed to be completely processor and operating system agnostic:

- **Processor Architectures**: Runs on `x86_64` / `amd64`, `aarch64` / `arm64`, or any architecture supported by the container runtime.
  - Native architecture builds are executed automatically without forcing foreign flags.
  - If cross-architecture emulation is needed (e.g., running x86_64 images on ARM64 or vice versa), the `--platform <os/arch>` parameter can be supplied explicitly without baking hardware assumptions into scripts.
- **Operating Systems**: Runs seamlessly on Linux (Fedora, RHEL, Debian, Ubuntu, openSUSE), macOS (with Podman Machine), and Windows (WSL2 with Podman).
- **Permissions & Security**: Supports both rootless and rootful Podman. Uses `:Z` SELinux volume relabeling flags to ensure compatibility across distributions with active SELinux enforcement (e.g., RHEL/Fedora).

---

## 4. Volume Persistence

All state is preserved in three named Podman volumes:
- `overleaf_data`: Holds uploaded user assets, projects, compiled artifacts, and user settings (`/var/lib/overleaf`).
- `overleaf_mongo_data`: Holds MongoDB database files (`/data/db`).
- `overleaf_redis_data`: Holds Redis append-only persistence files (`/data`).

Stopping or updating the stack does **not** delete these volumes. Volumes are only deleted if the user explicitly runs a cleanup with `--volumes`.
