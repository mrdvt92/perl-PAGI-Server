# PAGI::Runner Feature Comparison

Comparison of PAGI::Runner with Plack::Runner and Starman to identify feature gaps.

## Features PAGI::Runner Already Has

| Feature | PAGI | Plack |
|---------|------|-------|
| App file loading | `-a, --app` | `-a, --app` |
| Host binding | `-h, --host` | `-o, --host` |
| Port | `-p, --port` | `-p, --port` |
| Library paths | `-I, --lib` | `-I` |
| Access log | `--access-log` | `--access-log` |
| Help | `--help` | `-h, --help` |
| Quiet mode | `-q, --quiet` | - |
| **Multi-worker** | `-w, --workers` | (server-specific) |
| **SSL/TLS** | `--ssl-cert/key` | (server-specific) |
| **Event loop selection** | `-l, --loop` | - |
| **Log level** | `--log-level` | - |
| **Request timeout** | `--timeout` | (server-specific) |
| **Backlog** | `-b, --listener-backlog` | (server-specific) |
| **SO_REUSEPORT** | `--reuseport` | - |
| **Max requests/worker** | `--max-requests` | (server-specific) |
| **WebSocket limits** | `--max-ws-frame-size`, `--max-receive-queue` | - |
| **Disable access log** | `--no-access-log` | - |

## Features Missing from PAGI::Runner

| Feature | Plack/Starman | Priority | Use Case |
|---------|---------------|----------|----------|
| **Daemonize** | `-D, --daemonize` | HIGH | Production: run in background |
| **PID file** | `--pid` | HIGH | Production: process management, init scripts |
| **User/Group** | `--user, --group` | HIGH | Production: drop privileges after binding |
| **Graceful signals** | HUP/QUIT/TTIN/TTOU | HIGH | Production: zero-downtime restarts |
| Unix socket | `-S, --socket` | MEDIUM | Reverse proxy setups (nginx) |
| Environment | `-E, --env` | MEDIUM | Dev/staging/production modes |
| Version | `-v, --version` | MEDIUM | Basic CLI feature |
| Error log | `--error-log` | MEDIUM | Separate error logging |
| Auto-reload | `-r, --reload` | LOW | Development convenience |
| Module loading | `-M` | LOW | Pre-load modules |
| Inline code | `-e` | LOW | Quick testing |
| Process title | proctitle | LOW | Monitoring (ps output) |
| Multiple listen | `-l, --listen` | SKIP | Complex, rare use case |
| Server selection | `-s, --server` | N/A | PAGI is single server |
| Loader class | `-L, --loader` | N/A | PAGI has built-in loading |

## Priority Implementation List

### HIGH Priority (Production Essentials) - IMPLEMENTED

1. **`-D, --daemonize`** - Fork to background, detach from terminal ✅
2. **`--pid FILE`** - Write PID to file for process management ✅
3. **`--user USER` / `--group GROUP`** - Drop privileges after binding to port ✅
4. **Signal handling** - HUP (graceful restart), TTIN/TTOU (worker scaling) ✅

### MEDIUM Priority (Common Use Cases)

5. **`-S, --socket PATH`** - Listen on Unix domain socket
6. **`-E, --env NAME`** - Set PAGI_ENV (development/production/test)
7. **`-v, --version`** - Display version info ✅
8. **`--error-log FILE`** - Separate error log from access log

### LOW Priority (Development Convenience)

9. **`-r, --reload`** - Watch files and restart on changes
10. **`-M MODULE`** - Load modules before app
11. **Process title** - Set `$0` to "pagi-server master/worker"
