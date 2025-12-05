# TODO

## PAGI::Server

- When in multi-worker mode, add timeout to allow reaping children
- Review common server configuration options (from Uvicorn, Hypercorn, Starman)
- More logging levels and control (like Apache)
- Run compliance tests: HTTP/1.1, WebSocket, TLS, SSE
- UTF-8 testing for text, HTML, JSON

## PAGI::Simple

- Mount sub-applications under routes (like Mojolicious, Web::Simple)
- Static file serving: pass-through trick for reverse proxy (like Plack)
- Models layer (like Catalyst)
- Template rendering system
- Form validation helpers

## PubSub / Multi-Worker Considerations

**Decision (2024-12):** PubSub remains single-process (in-memory) by design.

### What We Learned

We explored adding IPC between parent and workers at the PAGI::Server level
to enable cross-worker PubSub. After research, we decided against it:

1. **Industry standard**: All major frameworks (Django Channels, Socket.io,
   Starlette) use in-memory for dev and Redis for production. Nobody does IPC.

2. **Why no IPC?**
   - IPC only works on one machine; Redis works across machines
   - If you need multi-worker, you'll soon need multi-server
   - External brokers provide: persistence, monitoring, pub/sub patterns
   - IPC adds complexity for a transitional use case

3. **PAGI philosophy**: PAGI::Server is a reference implementation, not the
   only option. Building IPC into it would couple PAGI::Simple to PAGI::Server.

### Current Design

- `PAGI::Simple::PubSub` uses in-memory backend (single-process)
- For multi-worker/multi-server: use Redis or similar external broker
- Document this limitation clearly in PubSub docs

### Future Options (if needed)

- Add pluggable backend API to PubSub (easy to add later)
- Provide Redis backend example in documentation
- Users can implement their own backends

## Documentation

- Scaling guide: single-worker vs multi-worker vs multi-server
- PubSub limitations and Redis migration path
- Performance tuning guide
