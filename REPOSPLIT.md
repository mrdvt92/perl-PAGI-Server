# PAGI Repository Split Plan

## Goal

Split PAGI::Simple into its own CPAN distribution (`PAGI-Simple`) separate from the core `PAGI` distribution (which contains PAGI::Server, PAGI::Runner, middleware, apps, etc.).

## Rationale

PAGI::Simple has grown into a full micro-framework with 30 modules (Simple.pm + 29 in Simple/) including:
- Routing, middleware, hooks
- Request/Response abstractions
- Views/templating with layouts and partials
- WebSocket and SSE contexts
- Services (PerApp, PerRequest, Factory patterns)
- PubSub for real-time messaging
- Form handling, file uploads, structured params

This is too large to bundle with the core PAGI server distribution.

## Current Structure

```
PAGI/
├── lib/
│   ├── PAGI.pm                    # Core spec docs
│   ├── PAGI/
│   │   ├── Server.pm              # STAYS - Reference server
│   │   ├── Server/                # STAYS - 7 modules
│   │   ├── Runner.pm              # STAYS - CLI loader
│   │   ├── Middleware/            # STAYS - ~37 modules
│   │   ├── App/                   # STAYS - ~17 modules
│   │   ├── Util/                  # STAYS - AsyncFile
│   │   ├── Simple.pm              # MOVES -> PAGI-Simple
│   │   └── Simple/                # MOVES -> 29 modules
├── bin/
│   └── pagi-server                # STAYS
├── share/
│   └── htmx/                      # MOVES -> PAGI-Simple (bundled assets)
├── examples/
│   ├── 01-hello-http/             # STAYS - raw PAGI examples
│   ├── ...
│   ├── simple-01-hello/           # MOVES -> PAGI-Simple (21 examples)
│   ├── simple-02-forms/           # MOVES
│   └── ...                        # (all simple-* directories move)
├── t/
│   ├── 01-hello-http.t            # STAYS
│   └── ...                        # (no simple-*.t tests currently exist)
└── docs/
    └── specs/                     # STAYS - PAGI specification
```

## Dependencies

**PAGI::Simple depends on these from PAGI:**
- `PAGI::App::Directory` - for `$app->static()` file serving
- `PAGI::Util::AsyncFile` - for async file I/O in views

These are self-contained modules with no dependency on PAGI::Server itself.

**Decision:** PAGI-Simple will depend on PAGI distribution. This is the Perlish way - you need a server to run the app anyway.

## Step-by-Step Split Process

### Phase 1: Create PAGI-Simple Repository

```bash
# 1. Clone fresh copy for the new repo
git clone /Users/jnapiorkowski/Desktop/PAGI /tmp/PAGI-Simple
cd /tmp/PAGI-Simple

# 2. Install git-filter-repo if needed
brew install git-filter-repo

# 3. Filter to only PAGI::Simple files (preserves their commit history)
git filter-repo \
  --path lib/PAGI/Simple.pm \
  --path lib/PAGI/Simple/ \
  --path share/ \
  --path-glob 'examples/simple-*'

# 4. Remove old remote
git remote remove origin

# 5. Move to final location
mv /tmp/PAGI-Simple /Users/jnapiorkowski/Desktop/PAGI-Simple
```

### Phase 2: Set Up PAGI-Simple Distribution

Create new `dist.ini` for PAGI-Simple:

```ini
name    = PAGI-Simple
version = 0.01
author  = John Napiorkowski <jnapiorkowski@cpan.org>
license = Perl_5
copyright_holder = John Napiorkowski

[Prereqs]
perl = 5.032
PAGI::Server = 0.001
Future::AsyncAwait = 0
IO::Async = 0
JSON::MaybeXS = 0
Scalar::Util = 0
# ... other deps

[Prereqs / TestRequires]
Test2::V0 = 0
```

Create `cpanfile`:

```perl
requires 'perl', '5.032';
requires 'PAGI::Server', '0.001';
requires 'Future::AsyncAwait';
requires 'IO::Async';
requires 'JSON::MaybeXS';
# ... etc

on test => sub {
    requires 'Test2::V0';
};
```

### Phase 3: Clean Up Original PAGI Repository

```bash
cd /Users/jnapiorkowski/Desktop/PAGI

# Remove PAGI::Simple files
rm lib/PAGI/Simple.pm
rm -rf lib/PAGI/Simple/

# Remove Simple examples
rm -rf examples/simple-*/

# Remove share directory (only used by Simple for htmx)
rm -rf share/

# Update dist.ini to remove PAGI::Simple references
# Update cpanfile

# Commit the removal
git add -A
git commit -m "chore: extract PAGI::Simple to separate distribution"
```

### Phase 4: Update Both Repositories

**In PAGI-Simple:**
- Update README.md with installation/usage
- Ensure all `use PAGI::App::Directory` etc. work (runtime dependency)
- Add note that it requires pagi-server to run

**In PAGI:**
- Update README.md to mention PAGI-Simple as separate install
- Update any docs that reference PAGI::Simple
- Ensure tests pass without Simple

### Phase 5: Publish

1. Push PAGI-Simple to new GitHub repo
2. Release PAGI to CPAN first (so PAGI-Simple can depend on it)
3. Release PAGI-Simple to CPAN

## Files to Move (Complete List)

```
lib/PAGI/Simple.pm
lib/PAGI/Simple/BodyStream.pm
lib/PAGI/Simple/Context.pm
lib/PAGI/Simple/CookieUtil.pm
lib/PAGI/Simple/Exception.pm
lib/PAGI/Simple/Handler.pm
lib/PAGI/Simple/Logger.pm
lib/PAGI/Simple/MultipartParser.pm
lib/PAGI/Simple/Negotiate.pm
lib/PAGI/Simple/PubSub.pm
lib/PAGI/Simple/Request.pm
lib/PAGI/Simple/Response.pm
lib/PAGI/Simple/Route.pm
lib/PAGI/Simple/Router.pm
lib/PAGI/Simple/SSE.pm
lib/PAGI/Simple/StreamWriter.pm
lib/PAGI/Simple/StructuredParams.pm
lib/PAGI/Simple/Upload.pm
lib/PAGI/Simple/View.pm
lib/PAGI/Simple/View/Helpers.pm
lib/PAGI/Simple/View/Helpers/Html.pm
lib/PAGI/Simple/View/Helpers/Htmx.pm
lib/PAGI/Simple/View/RenderContext.pm
lib/PAGI/Simple/View/Role/Valiant.pm
lib/PAGI/Simple/View/Vars.pm
lib/PAGI/Simple/WebSocket.pm
lib/PAGI/Simple/Service/_Base.pm
lib/PAGI/Simple/Service/Factory.pm
lib/PAGI/Simple/Service/PerApp.pm
lib/PAGI/Simple/Service/PerRequest.pm

share/htmx/
share/htmx/htmx.min.js
share/htmx/ext/sse.js
share/htmx/ext/ws.js

examples/simple-01-hello/
examples/simple-02-forms/
examples/simple-03-websocket/
examples/simple-04-sse/
examples/simple-05-streaming/
examples/simple-06-negotiation/
examples/simple-07-uploads/
examples/simple-08-cookies/
examples/simple-09-cors/
examples/simple-10-logging/
examples/simple-11-named-routes/
examples/simple-12-mount/
examples/simple-13-utf8/
examples/simple-14-streaming/
examples/simple-15-views/
examples/simple-16-layouts/
examples/simple-17-htmx-poll/
examples/simple-18-async-services/
examples/simple-19-valiant-forms/
examples/simple-20-worker-pool/
examples/simple-32-todo/
```

## Post-Split Verification

### In PAGI repo:
```bash
prove -l t/           # All tests pass
dzil build            # Builds successfully
pagi-server examples/01-hello-http/app.pl  # Works
```

### In PAGI-Simple repo:
```bash
prove -l t/           # All tests pass (with PAGI installed)
dzil build            # Builds successfully
pagi-server examples/simple-01-hello/app.pl  # Works
```

## Notes

- The split preserves git history for moved files using `git filter-repo`
- PAGI-Simple will have PAGI as a runtime dependency
- Users install: `cpanm PAGI-Server PAGI-Simple` (or just PAGI-Simple which pulls in PAGI-Server)
- The pagi-server binary stays in PAGI-Server distribution
- Current dist.ini names the distribution `PAGI-Server` (not `PAGI`)
- No `t/simple-*.t` tests currently exist (nothing to move for tests)
