# PAGI::Simple Form Processing Example

A comprehensive example demonstrating form handling, REST API patterns, and CRUD operations with the PAGI::Simple micro web framework.

## Quick Start

**1. Start the server:**

```bash
pagi-server --app examples/simple-02-forms/app.pl --port 5000
```

**2. Demo with curl (in another terminal):**

```bash
# List all contacts
curl http://localhost:5000/contacts
# => {"contacts":[{"id":1,"name":"John Doe",...},{"id":2,...}]}

# Create a new contact
curl -X POST http://localhost:5000/contacts \
  -d "name=Bob Wilson" -d "email=bob@example.com"
# => {"success":1,"contact":{"id":3,...}}

# Update a contact
curl -X PUT http://localhost:5000/contacts/1 \
  -H "Content-Type: application/json" \
  -d '{"name":"John Updated"}'
# => {"success":1,"contact":{...}}

# Delete a contact
curl -X DELETE http://localhost:5000/contacts/1
# => {"success":1,"message":"Contact 1 deleted"}
```

**3. Or use the browser:**

Open http://localhost:5000/ to see the HTML form interface.

## Features

- HTML form rendering
- POST form data processing
- JSON request/response APIs
- Full CRUD operations (Create, Read, Update, Delete)
- Input validation with error messages
- Query parameter search
- Bulk operations
- Custom error handlers (400, 404)

## Routes

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | HTML form for adding contacts |
| GET | `/contacts` | List all contacts (JSON) |
| GET | `/contacts/:id` | Get a single contact by ID |
| POST | `/contacts` | Create a new contact (form data) |
| PUT | `/contacts/:id` | Update a contact (JSON body) |
| DELETE | `/contacts/:id` | Delete a contact |
| GET | `/search?q=...` | Search contacts by name or email |
| POST | `/contacts/bulk` | Bulk create contacts (JSON array) |

## Usage Examples

### List All Contacts

```bash
curl http://localhost:5000/contacts
# => {"contacts":[{"id":1,"name":"John Doe","email":"john@example.com"},{"id":2,"name":"Jane Smith","email":"jane@example.com"}]}
```

### Get Single Contact

```bash
curl http://localhost:5000/contacts/1
# => {"id":1,"name":"John Doe","email":"john@example.com"}
```

### Create Contact (Form Data)

```bash
curl -X POST http://localhost:5000/contacts \
  -d "name=Bob Wilson" \
  -d "email=bob@example.com"
# => {"success":1,"contact":{"id":3,"name":"Bob Wilson","email":"bob@example.com"}}
```

### Create Contact (JSON)

```bash
curl -X POST http://localhost:5000/contacts \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "name=Alice&email=alice@example.com"
# => {"success":1,"contact":{"id":4,"name":"Alice","email":"alice@example.com"}}
```

### Update Contact

```bash
curl -X PUT http://localhost:5000/contacts/1 \
  -H "Content-Type: application/json" \
  -d '{"name":"John Updated","email":"john.updated@example.com"}'
# => {"success":1,"contact":{"id":1,"name":"John Updated","email":"john.updated@example.com"}}
```

### Delete Contact

```bash
curl -X DELETE http://localhost:5000/contacts/1
# => {"success":1,"message":"Contact 1 deleted"}
```

### Search Contacts

```bash
curl "http://localhost:5000/search?q=jane"
# => {"query":"jane","contacts":[{"id":2,"name":"Jane Smith","email":"jane@example.com"}]}
```

### Bulk Create

```bash
curl -X POST http://localhost:5000/contacts/bulk \
  -H "Content-Type: application/json" \
  -d '[{"name":"User1","email":"user1@test.com"},{"name":"User2","email":"user2@test.com"}]'
# => {"success":1,"created":2,"contacts":[...]}
```

### Validation Errors

```bash
curl -X POST http://localhost:5000/contacts \
  -d "name=" \
  -d "email=invalid"
# => {"success":0,"errors":["Name is required","Invalid email format"]}
```

## Code Highlights

### Async Form Processing

```perl
$app->post('/contacts' => async sub ($c) {
    my $name = await $c->param('name');
    my $email = await $c->param('email');

    # Validation
    my @errors;
    push @errors, 'Name is required' unless $name && length($name);
    push @errors, 'Invalid email format' if $email && $email !~ /\@/;

    if (@errors) {
        $c->status(400)->json({ success => 0, errors => \@errors });
        return;
    }

    # Create contact...
});
```

### JSON Body Parsing

```perl
$app->put('/contacts/:id' => async sub ($c) {
    my $id = $c->path_params->{id};
    my $body = await $c->req->json_body;

    $contact->{name} = $body->{name} if exists $body->{name};
    $contact->{email} = $body->{email} if exists $body->{email};

    $c->json({ success => 1, contact => $contact });
});
```

### Error Abort

```perl
$app->get('/contacts/:id' => sub ($c) {
    my $id = $c->path_params->{id};
    my ($contact) = grep { $_->{id} == $id } @contacts;

    if ($contact) {
        $c->json($contact);
    } else {
        $c->abort(404, "Contact $id not found");
    }
});
```
