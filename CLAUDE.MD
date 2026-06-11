# BeamWatch

Phoenix LiveView application for live incident triage of system logs. Reads log files from a local directory, detects active incidents, and lets operators acknowledge, silence, or resolve them.

## Key commands

```bash
mix setup                        # install deps + build assets
mix phx.server                   # start dev server at localhost:4000
mix test                         # run tests
mix precommit                    # full quality gate (format, credo, sobelow, dialyzer, coveralls)
mix coveralls.html               # coverage report → cover/
mix beamwatch.feed_logs --profile validation --target priv/logs --speed 20
```

## Project structure

```
lib/
  beamwatch/
    log_feed/          # log fixture feeder (dev/test only — not app business logic)
      cli.ex           # Mix task entrypoint
      runner.ex        # writes fixture entries to disk
      profiles.ex      # sample + validation fixture profiles
      fixtures.ex      # raw fixture data
  beamwatch_web/
    live/
      dashboard_live.ex  # main operator dashboard LiveView
    components/
      core_components.ex # shared UI components
config/
  config.exs           # compile-time config
  dev.exs              # dev config + live reload patterns
  runtime.exs          # runtime config (PORT, SECRET_KEY_BASE)
coveralls.json         # coverage config — 99% minimum, skip_files defined
```

## Quality pipeline

All of these run in `mix precommit` and in CI (`.github/workflows/pull-request.yml`):

| Step | Command |
|---|---|
| Compile | `mix compile --warnings-as-errors` |
| Unused deps | `mix deps.unlock --check-unused` |
| Format (+ Quokka) | `mix format --check-formatted` |
| Lint | `mix credo --strict` |
| Security | `mix sobelow --skip --config` |
| Types | `mix dialyzer --format github` |
| Coverage | `mix coveralls` (min 99%) |

CI splits into reusable workflows: `ci-quality.yml`, `ci-analysis.yml`, `ci-test.yml`.

## General conventions

- Elixir `~> 1.20`, OTP 27
- No Ecto — no database. State lives in-process.
- `MIX_ENV=test` for all quality tooling including dialyzer
- Quokka runs as a formatter plugin — `mix format` auto-rewrites style
- Coverage excludes: `lib/mix/tasks/`, `lib/beamwatch/log_feed/`, `lib/beamwatch/application.ex`, `lib/beamwatch_web/{gettext,endpoint,telemetry}.ex`, `lib/beamwatch_web.ex`, `lib/beamwatch.ex`
- Dialyzer PLT includes `:mix` and `:ex_unit` (set in `mix.exs`)

---

## Domain layer skills

All deep coding conventions live as skills under `.claude/skills/`. Load the one that matches what you're doing:

| Working on… | Skill |
|---|---|
| Context functions, plain modules, GenServers, business logic | `elixir-code-style` |
| Controllers, JSON APIs, webhooks | `phoenix-code-style` |
| LiveView, function components, HEEx, hooks | `phoenix-liveview-code-style` |
| Oban workers, queues, retries | `oban-code-style` |
| ExUnit tests | `elixir-testing-style` |

Each skill has an index `SKILL.md` and `references/*.md` for deeper rules — load only what the current task needs.

---

## LiveView conventions

### File responsibility split

Every LiveView **must** be split into two files:

- `my_live/index.ex` — logic only: `mount/3`, `handle_event/3`, `handle_info/2`, private helpers
- `my_live/index.html.heex` — markup only, no business logic

Omit `render/1` entirely and let Phoenix auto-render the matching `.html.heex` file:

```elixir
# CORRECT — no render/1, Phoenix picks up index.html.heex automatically
defmodule BeamWatchWeb.MyLive.Index do
  use BeamWatchWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "My Page")}
  end
end
```

**Never** use an inline `~H"""..."""` template inside the `.ex` file.

### For loops — always on HTML tags

Use the `:for` attribute directly on HTML elements. **Never** use `<%= for ... do %>` block expressions.

```heex
<%!-- CORRECT --%>
<ul>
  <li :for={item <- @items} id={item.id}>{item.name}</li>
</ul>

<%!-- CORRECT — streams --%>
<div id="items" phx-update="stream">
  <article :for={{dom_id, item} <- @streams.items} id={dom_id}>{item.name}</article>
</div>
```

### Mobile-first HTML

Write base (unprefixed) Tailwind classes for mobile, layer `sm:`/`md:`/`lg:` for larger screens. Touch targets must be ≥ 44px (`min-h-11` or `p-3`). Use `gap-*` on flex/grid parents instead of margins on children.

### Semantic markup

Use the correct HTML5 element. Never use `<div>` when a more specific element applies:

| Purpose | Element |
|---|---|
| Page sections | `<main>`, `<section>`, `<article>`, `<aside>` |
| Navigation | `<nav>` |
| Headings | `<h1>`–`<h6>` (one `<h1>` per page) |
| Lists | `<ul>` / `<ol>` + `<li>` |
| Data tables | `<table>`, `<thead>`, `<tbody>`, `<th scope="col/row">` |
| Forms | `<form>`, `<fieldset>`, `<legend>`, `<label for="...">` |
| Dates | `<time datetime="...">` |

### Boolean assigns — always use the `?` suffix

```elixir
# CORRECT
assign(socket, :incidents_empty?, list == [])
assign(socket, :panel_open?, false)
```

### PubSub subscriptions — always guard with `connected?/1`

```elixir
@impl true
def mount(_params, _session, socket) do
  if connected?(socket) do
    MyContext.subscribe()
  end
  {:ok, socket}
end
```

### Callback order

1. `use`, `alias`, `import` at top
2. `@impl true` callbacks in logical order (`mount`, `handle_params`, `handle_event`, `handle_info`)
3. `defp` private helpers at the bottom

### `handle_event` — always pattern match both outcomes

```elixir
# CORRECT
def handle_event("save", params, socket) do
  case MyContext.save(params) do
    {:ok, _result} -> {:noreply, put_flash(socket, :info, "Saved.")}
    {:error, reason} -> {:noreply, put_flash(socket, :error, reason)}
  end
end
```

### Stream naming — plural snake_case of the schema

```elixir
stream(socket, :incidents, list)      # schema Incident → :incidents
stream_delete(socket, :incidents, i)
```

---

## LiveView test conventions

### Module boilerplate

```elixir
defmodule BeamWatchWeb.MyLiveTest do
  use BeamWatchWeb.ConnCase

  import Phoenix.LiveViewTest
end
```

**Never** `use ExUnit.Case` directly — always `use BeamWatchWeb.ConnCase`.

### Mounting a LiveView

```elixir
{:ok, view, _html} = live(conn, ~p"/path")

# expect redirect
{:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/protected")
```

Always discard the initial render with `_html`. Use `view` and `has_element?` for all assertions including initial state.

### Assertions — always `has_element?`

**Never** use `html =~` or `render(view) =~`. They couple tests to raw HTML strings and give poor failure messages.

```elixir
# CORRECT
assert has_element?(view, "#incident-#{incident.id}")
assert has_element?(view, "button", "Acknowledge")
refute has_element?(view, "#incident-#{resolved.id}")

# WRONG
assert render(view) =~ "Incident"
assert html =~ "Acknowledge"
```

### Interactions

Always pass the visible text as the third argument to `element/3`. Never assert on the return value of `render_click()` — assert state with `has_element?` after:

```elixir
# CORRECT
view |> element("button", "Acknowledge") |> render_click()
assert has_element?(view, "#incident-#{incident.id}[data-status=acknowledged]")

# WRONG — asserts on render_click return value
assert view |> element("button", "Acknowledge") |> render_click() =~ "Acknowledged"

# WRONG — selector only, no text
view |> element("button") |> render_click()
```

### Forms

```elixir
view |> form("#my-form", resource: %{field: "value"}) |> render_change()
view |> form("#my-form", resource: @valid_attrs) |> render_submit()
```

### Redirect chains

```elixir
assert {:ok, dest_live, _html} =
         view |> form("#form", attrs) |> render_submit() |> follow_redirect(conn, ~p"/dest")

view |> element("a", "Details") |> render_click() |> follow_redirect(conn, ~p"/incidents/1")

# patch
view |> element("a", "Active") |> render_click()
assert_patch(view, ~p"/?filter=active")
```

### Application environment overrides

```elixir
test "handles missing config", %{conn: conn} do
  prev = Application.get_env(:beamwatch, :some_key)
  on_exit(fn -> Application.put_env(:beamwatch, :some_key, prev) end)
  Application.put_env(:beamwatch, :some_key, nil)
  ...
end
```

Always capture and restore the **full** previous value.

### `describe` block structure

Group by logical section of the page:

```elixir
describe "Index" do ... end
describe "Incident detail" do ... end
describe "Acknowledge flow" do ... end
describe "Silence flow" do ... end
describe "Access control" do ... end
```

### What NOT to test

- Internal assigns — test observable output, not `socket.assigns`
- CSS classes or visual styling
- Raw HTML strings — never `html =~` or `render(view) =~`
- Return value of `render_click()`
- `element/2` with selector only — always pass visible text as third arg

---

## Hooks

Hooks **must** follow this folder structure:

```
assets/js/hooks.js                    # index — imports and exports all hooks
assets/js/hooks/MyHook/index.js       # one folder per hook
```

`hooks.js`:

```js
import MyHook from "./hooks/MyHook";

let Hooks = { MyHook };
export default Hooks;
```

`hooks/MyHook/index.js`:

```js
const MyHook = {
  mounted() {
    this.el.addEventListener("click", () => {
      // hook logic
    });
  }
};
export default MyHook;
```

Hook tests go in the LiveView test file for the page that uses the hook. Test state before **and** after the hook fires:

```elixir
test "hook updates state", %{conn: conn} do
  {:ok, view, _html} = live(conn, ~p"/")

  # state before
  assert has_element?(view, "#before-state")

  view |> element("#trigger") |> render_hook("my_hook_event", %{})

  # state after
  assert has_element?(view, "#after-state")
end
```
