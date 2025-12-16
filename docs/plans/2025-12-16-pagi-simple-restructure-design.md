# PAGI::Simple Restructure Design

> **Status:** Draft for Review
> **Date:** 2025-12-16
> **Goal:** Enable structured, larger applications while keeping PAGI::Simple easy to understand from examples.

---

## 1. Overview

### Problem

PAGI::Simple works well for small single-file apps (`app.pl`), but struggles with larger applications:

- All routes in one file becomes unwieldy
- Mounted sub-apps don't share services with parent
- No clear pattern for organizing handlers/controllers
- `$c->app` returns the mounted sub-app, not the root application

### Solution

Refactor PAGI::Simple into composable pieces:

1. **PAGI::Simple::Application** - Shared application context (services, workers, views, home)
2. **PAGI::Simple::Router** - URL routing (get, post, group, mount, etc.)
3. **PAGI::Simple::Handler** - Controller-like class for grouping routes and handlers
4. **PAGI::Simple** - Combines Application + Router, backwards compatible

### Design Philosophy

- "Simple" means easy to understand from examples, not limited in features
- One way to compose: `mount` (behavior varies by what you mount)
- Handlers share the root Application's services
- Explicit over magical

---

## 2. Architecture

### Class Hierarchy

```
PAGI::Simple::Application    # Services, workers, views, home, config
PAGI::Simple::Router         # get, post, group, mount, etc.
PAGI::Simple                  # Combines Application + Router
PAGI::Simple::Handler        # Base class for controller-like handlers
```

### Responsibilities

| Class | Owns | Provides |
|-------|------|----------|
| Application | services, workers, views, home, config | `service()`, `home()`, `workers()` |
| Router | routes, mounted apps, groups | `get()`, `post()`, `mount()`, `group()` |
| PAGI::Simple | Application + Router | Everything (backwards compatible) |
| Handler | route definitions, handler methods | `routes($class, $app, $r)`, handler methods |

---

## 3. API Design

### 3.1 Simple Case (Unchanged)

Single-file apps continue to work exactly as before:

```perl
# app.pl
use PAGI::Simple;

my $app = PAGI::Simple->new(name => 'MyApp');

$app->get('/' => sub ($c) {
    $c->text('Hello World');
});

$app->get('/users/:id' => sub ($c) {
    $c->json({ id => $c->param('id') });
});

$app->to_app;
```

### 3.2 Class-Based Application

For larger apps, subclass PAGI::Simple:

```perl
# lib/TodoApp.pm
package TodoApp;
use parent 'PAGI::Simple';
use experimental 'signatures';

# Optional: class-level defaults (called before constructor args applied)
sub init ($class) {
    return (
        name    => 'TodoApp',
        quiet   => 1,
        share   => ['htmx'],
        workers => { max => 4 },
    );
}

# Define routes - called after construction
sub routes ($class, $app, $r) {
    # Mount external PAGI apps (isolated)
    $r->mount('/files' => 'PAGI::App::Directory', { root => './public' });

    # Mount handlers (share Application)
    $r->mount('/todos' => '::Todos');
    $r->mount('/users' => '::Users');
    $r->mount('/admin' => '::Admin', ['require_login']);

    # Inline routes
    $r->get('/' => '#home');
    $r->get('/health' => '#health');
}

# Handler methods
async sub home ($self, $c) {
    $c->redirect('/todos');
}

async sub health ($self, $c) {
    $c->json({ status => 'ok', time => time() });
}

1;
```

```perl
# app.pl (thin launcher)
use lib 'lib';
use TodoApp;

TodoApp->new->to_app;
```

### 3.3 Handlers

Handlers are controller-like classes that share the parent's Application:

```perl
# lib/TodoApp/Todos.pm
package TodoApp::Todos;
use parent 'PAGI::Simple::Handler';
use experimental 'signatures';

sub routes ($class, $app, $r) {
    # $app = root Application (TodoApp) - has services, home, etc.
    # $r = Router scoped to /todos prefix

    $r->get('/' => '#index');
    $r->get('/new' => '#new_form');
    $r->get('/:id' => '#load' => '#show');
    $r->get('/:id/edit' => '#load' => '#edit_form');
    $r->post('/' => '#create');
    $r->post('/:id' => '#load' => '#update');
    $r->post('/:id/delete' => '#load' => '#destroy');
}

# Middleware-style handler (called in chain)
async sub load ($self, $c) {
    my $id = $c->param('id');
    my $todo = $c->app->service('db')->find_todo($id);

    return $c->not_found unless $todo;
    $c->stash->{todo} = $todo;
}

# Action handlers
async sub index ($self, $c) {
    my $todos = $c->app->service('db')->all_todos;
    $c->render('todos/index', { todos => $todos });
}

async sub show ($self, $c) {
    $c->render('todos/show', { todo => $c->stash->{todo} });
}

async sub new_form ($self, $c) {
    $c->render('todos/new');
}

async sub edit_form ($self, $c) {
    $c->render('todos/edit', { todo => $c->stash->{todo} });
}

async sub create ($self, $c) {
    my $params = (await $c->body)
        ->namespace('todo')
        ->permitted(qw(title description))
        ->to_hash;

    my $todo = $c->app->service('db')->create_todo($params);
    $c->redirect("/todos/$todo->{id}");
}

async sub update ($self, $c) {
    my $params = (await $c->body)
        ->namespace('todo')
        ->permitted(qw(title description completed))
        ->to_hash;

    $c->app->service('db')->update_todo($c->stash->{todo}{id}, $params);
    $c->redirect("/todos/" . $c->stash->{todo}{id});
}

async sub destroy ($self, $c) {
    $c->app->service('db')->delete_todo($c->stash->{todo}{id});
    $c->redirect('/todos');
}

1;
```

### 3.4 Nested Handlers

Handlers can mount other handlers for deep nesting:

```perl
# lib/TodoApp/Admin.pm
package TodoApp::Admin;
use parent 'PAGI::Simple::Handler';
use experimental 'signatures';

sub routes ($class, $app, $r) {
    $r->get('/' => '#dashboard');

    # Nested handlers - relative class becomes TodoApp::Admin::Users
    $r->mount('/users' => '::Users', ['require_admin']);
    $r->mount('/settings' => '::Settings');
}

async sub dashboard ($self, $c) {
    $c->render('admin/dashboard');
}

1;
```

```perl
# lib/TodoApp/Admin/Users.pm
package TodoApp::Admin::Users;
use parent 'PAGI::Simple::Handler';
use experimental 'signatures';

sub routes ($class, $app, $r) {
    # Full path: /admin/users/
    $r->get('/' => '#index');
    $r->get('/:id' => '#show');
    $r->post('/:id/ban' => '#ban');
}

async sub index ($self, $c) {
    # $c->app is still TodoApp (root Application)
    my $users = $c->app->service('db')->all_users;
    $c->render('admin/users/index', { users => $users });
}

# ...

1;
```

### 3.5 Mount Signature

```perl
$r->mount($prefix, $app_spec);
$r->mount($prefix, $app_spec, \%constructor_args);
$r->mount($prefix, $app_spec, \@middleware);
$r->mount($prefix, $app_spec, \%constructor_args, \@middleware);
```

**Parameters:**

- `$prefix` - Path prefix (e.g., '/todos', '/api/v1')
- `$app_spec` - One of:
  - Class name string: `'MyApp::API'`
  - Relative class: `'::Todos'` (prepends caller's package)
  - PAGI::Simple instance
  - PAGI coderef
- `\%constructor_args` - Optional hash passed to `->new(%args)`
- `\@middleware` - Optional array of middleware names

**Behavior:**

```perl
sub mount ($self, $prefix, $app_spec, @args) {
    # ... resolve class, parse args ...

    my $app = $class->new(%constructor_args);

    if ($app->isa('PAGI::Simple::Handler')) {
        # Handler: share Application, call routes()
        $self->_mount_handler($prefix, $app, $middleware);
    } else {
        # External app: isolated (current behavior)
        $self->_mount_isolated($prefix, $app, $middleware);
    }
}
```

### 3.6 The `#method` Syntax

In routes, `'#method'` resolves to calling that method on the handler instance:

```perl
$r->get('/' => '#index');
# Becomes: async sub ($c) { await $handler->index($c) }

$r->get('/:id' => '#load' => '#show');
# Becomes middleware chain: load($c) then show($c)
```

**Handler method signature:**

```perl
async sub method_name ($self, $c) {
    # $self = handler instance (TodoApp::Todos)
    # $c = request context
    # $c->app = root Application (TodoApp)
}
```

---

## 4. Behavior Details

### 4.1 Handler Instantiation

Handlers are instantiated **once per application** at startup:

```perl
# In mount(), when mounting a Handler:
my $handler = $handler_class->new(app => $application, %constructor_args);
# $handler is stored and reused for all requests
```

**Implications:**
- Don't store per-request state in `$self`
- Use `$c->stash` for request-scoped data
- Handler can have configuration set at instantiation

### 4.2 Application Context

`$c->app` always returns the **root Application**, not the handler:

```perl
# In TodoApp::Admin::Users handler
async sub index ($self, $c) {
    $self;        # TodoApp::Admin::Users instance
    $c->app;      # TodoApp instance (root Application)

    $c->app->service('db');  # Access root's services
    $c->app->home;           # Project root directory
}
```

### 4.3 Middleware Stacking

Middleware accumulates through the handler tree:

```perl
# TodoApp routes:
$r->mount('/admin' => '::Admin', ['require_login']);

# TodoApp::Admin routes:
$r->mount('/users' => '::Users', ['require_admin']);

# Request to /admin/users/123 runs:
# 1. require_login (from TodoApp → Admin)
# 2. require_admin (from Admin → Users)
# 3. show handler
```

### 4.4 Relative Class Resolution

`::ClassName` is resolved relative to the caller's package:

| Called From | Spec | Resolves To |
|-------------|------|-------------|
| TodoApp | `'::Todos'` | TodoApp::Todos |
| TodoApp::Admin | `'::Users'` | TodoApp::Admin::Users |
| TodoApp | `'Other::App'` | Other::App |

### 4.5 Home Directory Detection

For class-based apps, `home` is the project root, detected by walking up from the class file looking for markers:

```perl
sub _find_project_root ($start_dir) {
    my $dir = $start_dir;
    my @markers = qw(cpanfile dist.ini Makefile.PL Build.PL .git);

    while ($dir ne '/') {
        for my $marker (@markers) {
            return $dir if -e "$dir/$marker";
        }
        $dir = dirname($dir);
    }
    return $start_dir;  # fallback
}
```

### 4.6 init() Method

Class-level defaults via `init()`:

```perl
sub init ($class) {
    return (
        name    => 'MyApp',
        quiet   => 1,
        workers => { max => 4 },
    );
}
```

**Precedence:** `init() defaults` < `constructor args`

```perl
# init returns quiet => 1
MyApp->new(quiet => 0);  # quiet => 0 wins
```

### 4.7 What's Not Inherited by Handlers

Handlers don't have their own:
- `workers` - Server-level, only root app
- `share` - Static assets mount at absolute paths
- `services` - Use `$c->app->service()` from root

Handlers may have their own:
- `views` configuration (optional, defaults to root's)

---

## 5. Complete Example

### Directory Structure

```
todo-app/
├── app.pl
├── cpanfile
├── lib/
│   ├── TodoApp.pm
│   └── TodoApp/
│       ├── Todos.pm
│       ├── Users.pm
│       ├── Admin.pm
│       ├── Admin/
│       │   ├── Users.pm
│       │   └── Settings.pm
│       └── Service/
│           └── DB.pm
└── templates/
    ├── layouts/
    │   └── default.html.ep
    ├── todos/
    │   ├── index.html.ep
    │   ├── show.html.ep
    │   └── ...
    └── admin/
        └── ...
```

### app.pl

```perl
#!/usr/bin/env perl
use lib 'lib';
use TodoApp;

TodoApp->new->to_app;
```

### lib/TodoApp.pm

```perl
package TodoApp;
use parent 'PAGI::Simple';
use experimental 'signatures';

sub init ($class) {
    return (
        name    => 'TodoApp',
        share   => ['htmx'],
        workers => { max => 4 },
        views   => { template_dir => 'templates' },
    );
}

sub services ($class, $app) {
    $app->service('db' => 'TodoApp::Service::DB');
}

sub routes ($class, $app, $r) {
    # Static files
    $r->mount('/files' => 'PAGI::App::Directory', { root => './public' });

    # Handlers
    $r->mount('/todos' => '::Todos');
    $r->mount('/users' => '::Users');
    $r->mount('/admin' => '::Admin', ['require_login']);

    # Top-level
    $r->get('/' => '#home');
    $r->get('/health' => '#health');
}

async sub home ($self, $c) {
    $c->redirect('/todos');
}

async sub health ($self, $c) {
    $c->json({ status => 'ok' });
}

1;
```

### lib/TodoApp/Todos.pm

```perl
package TodoApp::Todos;
use parent 'PAGI::Simple::Handler';
use experimental 'signatures';

sub routes ($class, $app, $r) {
    $r->get('/' => '#index');
    $r->get('/:id' => '#load' => '#show');
    $r->post('/' => '#create');
    $r->post('/:id' => '#load' => '#update');
}

async sub load ($self, $c) {
    my $todo = $c->app->service('db')->find_todo($c->param('id'));
    return $c->not_found unless $todo;
    $c->stash->{todo} = $todo;
}

async sub index ($self, $c) {
    my $todos = $c->app->service('db')->all_todos;
    $c->render('todos/index', { todos => $todos });
}

async sub show ($self, $c) {
    $c->render('todos/show', { todo => $c->stash->{todo} });
}

async sub create ($self, $c) {
    my $params = (await $c->body)->permitted(qw(title))->to_hash;
    my $todo = $c->app->service('db')->create_todo($params);
    $c->redirect("/todos/$todo->{id}");
}

async sub update ($self, $c) {
    my $params = (await $c->body)->permitted(qw(title completed))->to_hash;
    $c->app->service('db')->update_todo($c->stash->{todo}{id}, $params);
    $c->redirect("/todos/" . $c->stash->{todo}{id});
}

1;
```

---

## 6. Migration Path

### Backwards Compatibility

Existing PAGI::Simple apps continue to work unchanged:

```perl
# This still works exactly as before
my $app = PAGI::Simple->new;
$app->get('/' => sub ($c) { $c->text('Hello') });
$app->to_app;
```

### Gradual Adoption

1. **Start simple:** Single file with `PAGI::Simple->new`
2. **Add structure:** Move to class-based when needed
3. **Split handlers:** Extract routes into Handler classes
4. **Add services:** Share via Application

No big-bang rewrite required.

---

## 7. Implementation Tasks

1. **Create PAGI::Simple::Application**
   - Extract services, workers, views, home from PAGI::Simple
   - Add `init()` class method support
   - Add project root detection for `home`

2. **Create PAGI::Simple::Router**
   - Extract routing from PAGI::Simple
   - Already partially exists as internal implementation

3. **Create PAGI::Simple::Handler**
   - Base class with `routes($class, $app, $r)` pattern
   - `#method` resolution to handler methods
   - Store reference to root Application

4. **Update PAGI::Simple**
   - Compose Application + Router
   - Support `routes($class, $app, $r)` when subclassed
   - Support `init()` class method

5. **Update mount()**
   - Detect ISA Handler
   - Pass Application to Handler's routes()
   - Ensure `$c->app` returns root Application

6. **Tests**
   - Handler mounting and nesting
   - Service sharing across handlers
   - Middleware stacking
   - Backwards compatibility
   - `$c->app` always returns root

7. **Documentation**
   - Update PAGI::Simple POD
   - Create PAGI::Simple::Handler POD
   - Add examples in examples/ directory

---

## 8. Open Questions

1. **Handler constructor args:** How should `%args` passed to mount be used?
   - Option A: Passed to `->new(%args)`
   - Option B: Available via `$self->{config}` or similar

2. **services() method:** Should this be a class method like routes()?
   - Current: `$app->service('name' => 'Class')` in routes()
   - Alternative: `sub services ($class, $app) { ... }` separate method

3. **Views per handler:** Should handlers be able to override template directory?
   - Probably yes, for handler-specific templates

4. **Error handling:** Should handlers have their own error handlers?
   - Or inherit from root Application?

---

## 9. Future Considerations

- **Form Objects:** Handler + Form object integration (see TODO.md)
- **Before/After filters:** Rails-style `before_action` in handlers
- **Attribute-based routing:** `sub index :Get('/') ($self, $c) { ... }`
- **Auto-discovery:** Automatically find handlers in lib/MyApp/
