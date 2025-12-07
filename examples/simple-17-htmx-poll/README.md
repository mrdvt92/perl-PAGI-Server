# Live Poll Example - htmx Integration Demo

This example demonstrates PAGI::Simple's htmx template helpers for building interactive, real-time web applications.

## Running

```bash
pagi-server --app examples/simple-17-htmx-poll/app.pl --port 5000
```

Then visit: http://localhost:5000

## Features Demonstrated

### htmx Template Helpers

| Helper | Usage in this demo |
|--------|-------------------|
| `htmx()` | Includes htmx.min.js in layout |
| `htmx_sse()` | Includes SSE extension for live updates |
| `hx_post()` | Create polls, submit votes |
| `hx_delete()` | Delete polls with confirmation dialog |
| `hx_sse()` | Watch polls with live vote updates |

### View System Features

- **Layouts**: `extends('layouts/default')` for consistent page structure
- **Partials**: `include('polls/_card', poll => $poll)` for reusable components
- **content_for**: Inject styles/scripts from pages into layout slots

## How It Works

### 1. Creating Polls (`hx_post`)
```html
<form <%= hx_post('/polls/create',
                  target => '#polls',
                  swap => 'afterbegin') %>>
```
When submitted, htmx POSTs the form and prepends the new poll to the list.

### 2. Voting (`hx_post` with `vals`)
```html
<button <%= hx_post("/polls/$id/vote",
                    vals => { option => $opt },
                    target => "#poll-$id",
                    swap => 'outerHTML') %>>
```
Click to vote - htmx sends the vote and swaps in the updated poll card.

### 3. Deleting Polls (`hx_delete` with `confirm`)
```html
<button <%= hx_delete("/polls/$id",
                      target => "#poll-$id",
                      swap => 'outerHTML',
                      confirm => 'Delete this poll?') %>>
```
Shows confirmation dialog before deleting.

### 4. Live Updates (`hx_sse`)
```html
<div <%= hx_sse("/polls/$id/live", swap => 'innerHTML') %>>
    <div sse-swap="vote">
        <!-- Poll card updates here when votes come in -->
    </div>
</div>
```
Opens SSE connection and updates the poll in real-time when others vote.

## File Structure

```
examples/simple-17-htmx-poll/
  app.pl                         # Main application
  templates/
    layouts/
      default.html.ep            # Base layout with htmx
    index.html.ep                # Home page with poll list
    polls/
      _card.html.ep              # Poll card partial
      watch.html.ep              # Live watch page with SSE
```

## Try It

1. **Create a poll**: Fill in the question and options, click Create
2. **Vote**: Click any option to vote (bar updates instantly)
3. **Watch live**: Click "Watch live" on a poll, then vote from another tab
4. **Delete**: Click Delete on any poll (confirms first)

## Key Takeaways

- **No JavaScript written** - htmx handles all interactions declaratively
- **Partial updates** - Only changed parts of the page update
- **Real-time** - SSE provides live updates without polling
- **Progressive** - Works without JS (forms still submit normally)
