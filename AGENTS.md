# AGENTS.md

This file defines the development guidelines and agent behaviour for this Phoenix web application. All agents (AI or human) must follow these rules when contributing to this codebase.

---

## Project Guidelines

- Use `mix precommit` alias when done with **all** changes and fix any pending issues before marking a task complete.
- Use the already-included `:req` (`Req`) library for HTTP requests. **Never** use `:httpoison`, `:tesla`, or `:httpc`.
- **Always** read and re-read these guidelines before generating code. Violating any rule here is a critical error.

---

## Agent Workflow

Before writing any code, agents **must**:

1. **Understand the task** — re-read the prompt/issue carefully.
2. **Identify affected modules** — list the files and contexts that will change.
3. **Plan before coding** — outline the approach in comments or a scratchpad before generating code.
4. **Follow Gitflow**:
   - Branch off `develop` for all feature and fix work.
   - Use `--no-ff` merges.
   - Use [Conventional Commits](https://www.conventionalcommits.org/) for all commit messages (`feat:`, `fix:`, `chore:`, `refactor:`, `docs:`, etc.).
5. **Run `mix precommit`** after all changes. Fix all warnings and errors before finalising.

---

## Elixir Guidelines

- Elixir lists **do not support index-based access via the access syntax**.

  **Never do this (invalid):**
  ```elixir
  mylist[0]
  ```

  **Always use:**
  ```elixir
  Enum.at(mylist, 0)
  ```

- Variables are immutable but can be rebound. **Always bind the result of block expressions** (`if`, `case`, `cond`) to a variable:

  ```elixir
  # INVALID
  if connected?(socket) do
    socket = assign(socket, :val, val)
  end

  # VALID
  socket =
    if connected?(socket) do
      assign(socket, :val, val)
    end
  ```

- **Never** nest multiple modules in the same file — it causes cyclic dependencies and compilation errors.
- **Never** use map access syntax (`changeset[:field]`) on structs. Access struct fields directly (`my_struct.field`) or use `Ecto.Changeset.get_field/2`.
- **Never** use `String.to_atom/1` on user input (memory leak risk).
- Predicate function names should **not** start with `is_` — they should end with `?`. Reserve `is_*` for guards.
- Use Elixir's standard library (`Time`, `Date`, `DateTime`, `Calendar`) for date/time manipulation. Only install `date_time_parser` for parsing edge cases. **Never** add other date libraries.
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration. Default to `timeout: :infinity` unless you have a specific timeout requirement.
- OTP primitives like `DynamicSupervisor` and `Registry` **require names in the child spec**:

  ```elixir
  {DynamicSupervisor, name: MyApp.MyDynamicSup}
  DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)
  ```

- Elixir supports `if/else` but **does NOT support `if/else if` or `elsif`**. Always use `cond` or `case` for multiple branches:

  ```elixir
  # INVALID
  if condition do ... else if other_condition do ... end

  # VALID
  cond do
    condition -> ...
    other_condition -> ...
    true -> ...
  end
  ```

---

## Mix Guidelines

- Run `mix help task_name` before using unfamiliar mix tasks to check options.
- Debug test failures with `mix test test/my_test.exs` or `mix test --failed`.
- **Avoid** `mix deps.clean --all` unless you have strong reason to do so.

---

## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates.
- Remember to `import Ecto.Query` and supporting modules in `seeds.exs`.
- `Ecto.Schema` fields always use `:string` for text columns, not `:text`.
- `Ecto.Changeset.validate_number/2` **does not support** the `:allow_nil` option — it's unnecessary as Ecto skips validations for nil changes by default.
- **Always** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields.
- Fields set programmatically (e.g., `user_id`) **must not** appear in `cast/3` calls — set them explicitly when building the struct.
- **Always** use `mix ecto.gen.migration migration_name_in_underscores` to generate migration files.

---

## Test Guidelines

- **Always** use `start_supervised!/1` to start processes in tests — it guarantees cleanup between tests.
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests.
- To wait for a process to finish, use `Process.monitor/1` and assert on the DOWN message:

  ```elixir
  ref = Process.monitor(pid)
  assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  ```

- To synchronise before the next call, use `_ = :sys.get_state/1` to ensure the process has handled prior messages.
- Use `Phoenix.LiveViewTest` and `LazyHTML` for LiveView assertions.
- **Always** reference key DOM IDs in tests (`has_element?(view, "#my-form")`).
- **Never** test against raw HTML — use `element/2`, `has_element/2`, and similar helpers.
- Focus on testing outcomes, not implementation details.
- When selectors fail, debug using `LazyHTML`:

  ```elixir
  html = render(view)
  document = LazyHTML.from_fragment(html)
  matches = LazyHTML.filter(document, "your-selector")
  IO.inspect(matches, label: "Matches")
  ```

---

## Phoenix Guidelines

- `scope` blocks in the router provide an alias — **never** create your own alias for route definitions inside a scope:

  ```elixir
  scope "/admin", AppWeb.Admin do
    pipe_through :browser
    live "/users", UserLive, :index  # resolves to AppWeb.Admin.UserLive
  end
  ```

- `Phoenix.View` is **no longer included** in Phoenix — do not use it.

---

## Phoenix v1.8 Guidelines

- **Always** begin LiveView templates with `<Layouts.app flash={@flash} ...>` wrapping all inner content.
- `MyAppWeb.Layouts` is aliased in `my_app_web.ex` — no need to alias it again.
- If you encounter a `no current_scope assign` error:
  - You have failed to follow Authenticated Routes guidelines, or failed to pass `current_scope` to `<Layouts.app>`.
  - Fix it by moving routes to the correct `live_session` and passing `current_scope` as needed.
- `<.flash_group>` has moved to the `Layouts` module — **never** call it outside of `layouts.ex`.
- Always use the `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for icons. **Never** use `Heroicons` modules directly.
- Always use the imported `<.input>` component from `core_components.ex` for form inputs. If you override the default classes, you must fully re-style the input — no defaults are inherited.

---

## Phoenix HTML Guidelines

- Templates always use `~H` or `.html.heex` (HEEx). **Never** use `~E`.
- **Always** use `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1`. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for`.
- Always use `to_form/2` assigned in the LiveView and drive forms from `@form[:field]` in templates:

  ```heex
  <.form for={@form} id="product-form" phx-change="validate" phx-submit="save">
    <.input field={@form[:name]} type="text" />
  </.form>
  ```

- **Never** access a changeset directly in a template — always use a `to_form/2` assigned form.
- Always add unique DOM IDs to key elements (forms, buttons, etc.).
- For app-wide imports, add them to the `html_helpers` block in `my_app_web.ex`.
- HEEx interpolation rules:
  - Use `{...}` for attribute and inline value interpolation.
  - Use `<%= ... %>` for block constructs (`if`, `cond`, `case`, `for`) inside tag bodies.
  - **Never** use `<%= %>` inside tag attributes.
- Conditional classes should always use list syntax:

  ```heex
  <a class={[
    "px-2 text-white",
    @some_flag && "py-5",
    if(@other_condition, do: "border-red-500", else: "border-blue-100")
  ]}>
  ```

- For literal `{` or `}` in `<pre>` or `<code>` blocks, annotate the parent with `phx-no-curly-interpolation`.
- HEEx comments use `<%!-- comment --%>`.
- **Never** use `<% Enum.each %>` for template content — always use `<%= for item <- @collection do %>`.

---

## Phoenix LiveView Guidelines

- **Never** use deprecated `live_redirect` or `live_patch`. Use `<.link navigate={}>`, `<.link patch={}>`, `push_navigate/2`, and `push_patch/2`.
- **Avoid LiveComponents** unless you have a strong, specific reason (e.g., isolated stateful UI with its own lifecycle).
- LiveViews should be named with a `Live` suffix: `AppWeb.WeatherLive`.

### LiveView Streams

- **Always** use LiveView streams for collections — never assign plain lists to avoid memory issues:

  ```elixir
  stream(socket, :messages, [new_msg])                        # append
  stream(socket, :messages, [new_msg], reset: true)           # reset
  stream(socket, :messages, [new_msg], at: -1)                # prepend
  stream_delete(socket, :messages, msg)                        # delete
  ```

- Stream templates must use `phx-update="stream"` on the parent with a DOM id:

  ```heex
  <div id="messages" phx-update="stream">
    <div :for={{id, msg} <- @streams.messages} id={id}>
      {msg.text}
    </div>
  </div>
  ```

- Streams are **not enumerable** — you cannot `Enum.filter/2` them. To filter, refetch and re-stream with `reset: true`.
- Streams **do not support counting or empty states natively**. Track counts with a separate assign. For empty states, use Tailwind's `only:block`:

  ```heex
  <div id="tasks" phx-update="stream">
    <div class="hidden only:block">No tasks yet</div>
    <div :for={{id, task} <- @streams.tasks} id={id}>{task.name}</div>
  </div>
  ```

- When an assign that affects a streamed item changes, **always re-stream the item** via `stream_insert/3`.
- **Never** use deprecated `phx-update="append"` or `phx-update="prepend"`.

### LiveView JavaScript Interop

- When a `phx-hook` manages its own DOM, always also set `phx-update="ignore"`.
- Always provide a unique DOM id alongside `phx-hook`.

#### Colocated JS Hooks (inline scripts)

**Never** write raw `<script>` tags in HEEx. Use colocated hook script tags:

```heex
<input id="user-phone" phx-hook=".PhoneNumber" type="text" />
<script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
  export default {
    mounted() {
      this.el.addEventListener("input", e => {
        let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
        if (match) this.el.value = `${match[1]}-${match[2]}-${match[3]}`
      })
    }
  }
</script>
```

- Colocated hook names **must** start with a `.` prefix.

#### External JS Hooks

Place in `assets/js/` and pass to the `LiveSocket` constructor:

```js
const MyHook = { mounted() { ... } }
let liveSocket = new LiveSocket("/live", Socket, { hooks: { MyHook } });
```

#### Pushing Events

```elixir
socket = push_event(socket, "my_event", %{key: "value"})
```

```js
mounted() {
  this.handleEvent("my_event", data => console.log(data));
}
```

---

## JS and CSS Guidelines

- Use **Tailwind CSS classes and custom CSS rules** for all styling.
- Tailwind v4 uses a new import syntax in `app.css` — **always maintain this**:

  ```css
  @import "tailwindcss" source(none);
  @source "../css";
  @source "../js";
  @source "../../lib/my_app_web";
  ```

- **Never** use `@apply` in raw CSS.
- **Never** use daisyUI — always write your own Tailwind-based components.
- Only `app.js` and `app.css` bundles are supported out of the box:
  - Never reference external vendor scripts/styles via `src` or `href` in layouts.
  - Import all vendor dependencies into `app.js` and `app.css`.
  - **Never** write inline `<script>custom js</script>` tags in templates.

---

## UI/UX & Design Guidelines

- Produce **world-class UI designs** with a focus on usability, aesthetics, and modern design principles.
- Implement **subtle micro-interactions** (button hover effects, smooth transitions).
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look.
- Focus on **delightful details**: hover effects, loading states, smooth page transitions.