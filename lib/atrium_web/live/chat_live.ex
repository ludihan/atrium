defmodule AtriumWeb.ChatLive do
  @moduledoc """
  The whole app: a nick prompt, a list of channels down the side, and one
  message pane.
  """
  use AtriumWeb, :live_view

  alias Atrium.Chat
  alias AtriumWeb.Presence

  @blocked_notice_ttl :timer.seconds(4)
  @max_visible_notices 4
  @presence_topic "chat:presence"

  @impl true
  def mount(_params, _session, socket) do
    channels = Chat.list_channels()
    current = Enum.find(channels, &(&1.name == "general")) || List.first(channels)

    if connected?(socket) do
      Chat.subscribe_directory()
      if current, do: Chat.subscribe(current)
      Phoenix.PubSub.subscribe(Atrium.PubSub, @presence_topic)
    end

    socket =
      socket
      |> assign(:page_title, "atrium")
      |> assign(:nick, nil)
      |> assign(:presence_key, nil)
      |> assign(:channels, channels)
      |> assign(:current, current)
      |> assign(:online_users, online_users_by_channel())
      |> assign(:replying_to, nil)
      |> assign(:mobile_panel, nil)
      |> assign(:blocked_notices, [])
      |> assign(:nick_form, to_form(%{"nick" => ""}, as: :join))
      |> assign(:msg_form, to_form(%{"body" => ""}, as: :chat))
      |> stream(:messages, (current && Chat.list_recent_messages(current)) || [], limit: -100)

    {:ok, socket}
  end

  @impl true
  def handle_event("set_nick", %{"join" => %{"nick" => nick}}, socket) do
    case sanitize_nick(nick) do
      "" ->
        {:noreply, put_flash(socket, :error, "Pick a nick with letters or numbers.")}

      nick ->
        {:noreply, socket |> assign(:nick, nick) |> refresh_messages() |> track_presence()}
    end
  end

  def handle_event("switch", %{"name" => name}, socket) do
    case Enum.find(socket.assigns.channels, &(&1.name == name)) do
      nil -> {:noreply, socket}
      channel -> {:noreply, switch_channel(socket, channel)}
    end
  end

  def handle_event("send", %{"chat" => %{"body" => body}}, socket) do
    {:noreply, handle_input(socket, String.trim(body))}
  end

  def handle_event("reply", %{"id" => id}, socket) do
    case Chat.get_message(id) do
      %Chat.Message{} = message -> {:noreply, assign(socket, :replying_to, message)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("cancel_reply", _params, socket) do
    {:noreply, assign(socket, :replying_to, nil)}
  end

  def handle_event("toggle_mobile_panel", %{"panel" => panel}, socket) do
    panel = String.to_existing_atom(panel)
    new_panel = if socket.assigns.mobile_panel == panel, do: nil, else: panel
    {:noreply, assign(socket, :mobile_panel, new_panel)}
  end

  def handle_event("close_mobile_panel", _params, socket) do
    {:noreply, assign(socket, :mobile_panel, nil)}
  end

  @impl true
  def handle_info({:new_message, message}, socket) do
    if socket.assigns.current && message.channel_id == socket.assigns.current.id do
      {:noreply, stream_insert(socket, :messages, message, limit: -100)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:channels, channels}, socket) do
    {:noreply, assign(socket, :channels, channels)}
  end

  def handle_info({:dismiss_blocked_notice, id}, socket) do
    {:noreply,
     update(socket, :blocked_notices, &Enum.reject(&1, fn notice -> notice.id == id end))}
  end

  def handle_info(%{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :online_users, online_users_by_channel())}
  end

  ## Input handling

  defp handle_input(socket, ""), do: socket

  defp handle_input(socket, "/" <> rest) do
    {command, arg} =
      case String.split(rest, " ", parts: 2) do
        [command, arg] -> {String.downcase(command), String.trim(arg)}
        [command] -> {String.downcase(command), ""}
      end

    run_command(socket, command, arg)
  end

  defp handle_input(%{assigns: %{nick: nil}} = socket, _body) do
    put_flash(socket, :error, "Choose a nick first.")
  end

  defp handle_input(socket, body) do
    post(socket, body, "said")
  end

  defp run_command(socket, cmd, arg) when cmd in ~w(join j) do
    case Chat.get_or_create_channel(arg) do
      {:ok, channel} ->
        socket
        |> update(:channels, &insert_channel(&1, channel))
        |> switch_channel(channel)

      {:error, _changeset} ->
        put_flash(socket, :error, "\"#{arg}\" is not a valid channel name.")
    end
  end

  defp run_command(socket, cmd, arg) when cmd in ~w(nick n) do
    case sanitize_nick(arg) do
      "" ->
        put_flash(socket, :error, "Usage: /nick <name>")

      nick ->
        socket
        |> assign(:nick, nick)
        |> refresh_messages()
        |> track_presence()
        |> clear_input()
    end
  end

  defp run_command(socket, "me", arg) when arg != "" do
    post(socket, arg, "emote")
  end

  defp run_command(socket, "help", _arg) do
    socket
    |> clear_input()
    |> put_flash(:info, "Commands: /join #channel · /nick name · /me action")
  end

  defp run_command(socket, cmd, _arg) do
    put_flash(socket, :error, "Unknown command: /#{cmd}")
  end

  defp post(%{assigns: %{nick: nil}} = socket, _body, _kind) do
    put_flash(socket, :error, "Choose a nick first.")
  end

  defp post(%{assigns: %{current: nil}} = socket, _body, _kind) do
    put_flash(socket, :error, "Join a channel first with /join #channel.")
  end

  defp post(socket, body, kind) do
    reply_to = socket.assigns.replying_to

    case Chat.post_message(socket.assigns.current, socket.assigns.nick, body, kind, reply_to) do
      {:ok, _message} ->
        socket
        |> assign(:replying_to, nil)
        |> clear_input()

      {:ok, _message, {:warn, meta}} ->
        socket
        |> assign(:replying_to, nil)
        |> clear_input()
        |> show_blocked_notice(
          "Sent, but this message might break the channel rules (#{meta.category}, #{meta.severity})."
        )

      {:error, {:moderated, meta}} ->
        show_blocked_notice(
          socket,
          "Message blocked: breaks the channel rules (#{meta.category}, #{meta.severity})."
        )

      {:error, _changeset} ->
        put_flash(socket, :error, "Message was not sent.")
    end
  end

  defp show_blocked_notice(socket, text) do
    id = "blocked-#{System.unique_integer([:positive, :monotonic])}"
    Process.send_after(self(), {:dismiss_blocked_notice, id}, @blocked_notice_ttl)
    update(socket, :blocked_notices, &[%{id: id, text: text} | &1])
  end

  defp visible_notices(notices), do: Enum.take(notices, @max_visible_notices)

  defp hidden_notice_count(notices), do: max(length(notices) - @max_visible_notices, 0)

  defp switch_channel(socket, channel) do
    socket = assign(socket, :mobile_panel, nil)

    if socket.assigns.current && socket.assigns.current.id == channel.id do
      clear_input(socket)
    else
      if connected?(socket) do
        if socket.assigns.current, do: Chat.unsubscribe(socket.assigns.current)
        Chat.subscribe(channel)

        if key = socket.assigns.presence_key do
          Presence.update(self(), @presence_topic, key, %{channel_id: channel.id})
        end
      end

      socket
      |> assign(:current, channel)
      |> assign(:replying_to, nil)
      |> clear_input()
      |> stream(:messages, Chat.list_recent_messages(channel), reset: true)
    end
  end

  defp refresh_messages(%{assigns: %{current: nil}} = socket), do: socket

  defp refresh_messages(socket) do
    stream(socket, :messages, Chat.list_recent_messages(socket.assigns.current), reset: true)
  end

  defp track_presence(%{assigns: %{current: nil}} = socket), do: socket

  defp track_presence(socket) do
    %{nick: nick, current: channel, presence_key: presence_key} = socket.assigns

    if connected?(socket) and presence_key != nick do
      if presence_key, do: Presence.untrack(self(), @presence_topic, presence_key)
      Presence.track(self(), @presence_topic, nick, %{channel_id: channel.id})
    end

    assign(socket, :presence_key, nick)
  end

  defp online_users_by_channel do
    @presence_topic
    |> Presence.list()
    |> Enum.reduce(%{}, fn {nick, %{metas: metas}}, acc ->
      metas
      |> Enum.map(& &1.channel_id)
      |> Enum.uniq()
      |> Enum.reduce(acc, fn channel_id, acc2 ->
        Map.update(acc2, channel_id, [nick], &[nick | &1])
      end)
    end)
  end

  defp online_users_for(_online_users, nil), do: []

  defp online_users_for(online_users, channel) do
    online_users |> Map.get(channel.id, []) |> Enum.sort()
  end

  defp clear_input(socket) do
    socket
    |> assign(:msg_form, to_form(%{"body" => ""}, as: :chat))
    |> push_event("clear-input", %{id: "chat-body"})
  end

  defp insert_channel(channels, channel) do
    channels
    |> Enum.reject(&(&1.id == channel.id))
    |> Kernel.++([channel])
    |> Enum.sort_by(& &1.name)
  end

  defp sanitize_nick(nick) do
    nick
    |> to_string()
    |> String.trim()
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/[^A-Za-z0-9_\-\[\]\\^`{}|]/, "")
    |> String.slice(0, 24)
  end

  ## Mentions ("@nick")

  @mention_regex ~r/@[A-Za-z0-9_\-\[\]\\^`{}|]{1,24}/

  defp render_segments(body) do
    @mention_regex
    |> Regex.split(body, include_captures: true, trim: true)
    |> Enum.map(fn
      "@" <> nick -> {:mention, nick}
      text -> {:text, text}
    end)
  end

  defp mentions?(_body, nil), do: false

  defp mentions?(body, nick) do
    body
    |> render_segments()
    |> Enum.any?(fn
      {:mention, mentioned} -> String.downcase(mentioned) == String.downcase(nick)
      _ -> false
    end)
  end

  defp mention_html(body, nick) do
    body
    |> render_segments()
    |> Enum.map(fn
      {:text, text} ->
        Phoenix.HTML.Engine.encode_to_iodata!(text)

      {:mention, mentioned} ->
        classes =
          if nick && String.downcase(mentioned) == String.downcase(nick) do
            "rounded px-1 bg-primary/25 font-semibold text-primary"
          else
            "rounded px-1 bg-primary/10 text-primary"
          end

        [
          ~s(<span class="),
          classes,
          ~s(">@),
          Phoenix.HTML.Engine.encode_to_iodata!(mentioned),
          ~s(</span>)
        ]
    end)
    |> IO.iodata_to_binary()
    |> Phoenix.HTML.raw()
  end

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:header>
        <button
          type="button"
          phx-click="toggle_mobile_panel"
          phx-value-panel="channels"
          class="rounded p-1 text-base-content/60 hover:text-base-content md:hidden"
          aria-label="Toggle channels"
        >
          <.icon name="hero-bars-3" class="size-5" />
        </button>
        <span :if={@nick} class="font-mono text-xs text-base-content/70">
          you are <span class="font-semibold text-base-content">{@nick}</span>
        </span>
        <button
          type="button"
          phx-click="toggle_mobile_panel"
          phx-value-panel="online"
          class="rounded p-1 text-base-content/60 hover:text-base-content md:hidden"
          aria-label="Toggle online users"
        >
          <.icon name="hero-users" class="size-5" />
        </button>
      </:header>

      <div
        id="blocked-notices"
        class="pointer-events-none fixed inset-x-0 top-3 z-50 flex flex-col items-center gap-2 px-4"
      >
        <div
          :for={notice <- visible_notices(@blocked_notices)}
          id={notice.id}
          phx-remove={hide("##{notice.id}")}
          class="pointer-events-auto rounded-md border border-error/30 bg-error px-3 py-1.5 font-mono text-xs font-medium text-error-content shadow-lg"
        >
          {notice.text}
        </div>
        <p
          :if={hidden_notice_count(@blocked_notices) > 0}
          class="pointer-events-none font-mono text-[0.65rem] text-base-content/50"
        >
          +{hidden_notice_count(@blocked_notices)} more waiting…
        </p>
      </div>

      <div class="relative flex h-full min-h-0">
        <div
          :if={@mobile_panel}
          class="fixed inset-0 z-30 bg-black/30 md:hidden"
          phx-click="close_mobile_panel"
        />

        <aside class={[
          "w-64 shrink-0 flex-col overflow-y-auto border-r border-base-300 bg-base-100 md:static md:z-auto md:flex md:w-44 md:bg-base-200/50",
          if(@mobile_panel == :channels, do: "fixed inset-y-0 left-0 z-40 flex", else: "hidden")
        ]}>
          <div class="flex items-center justify-between px-3 py-2">
            <p class="text-[0.7rem] font-semibold uppercase tracking-wider text-base-content/40">
              Channels
            </p>
            <button
              type="button"
              phx-click="close_mobile_panel"
              class="text-base-content/40 hover:text-base-content md:hidden"
              aria-label="Close"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <nav class="flex-1 overflow-y-auto pb-2">
            <button
              :for={channel <- @channels}
              type="button"
              phx-click="switch"
              phx-value-name={channel.name}
              class={[
                "block w-full truncate px-3 py-1 text-left font-mono text-sm transition-colors",
                @current && @current.id == channel.id && "bg-primary/10 text-primary",
                !(@current && @current.id == channel.id) &&
                  "text-base-content/70 hover:bg-base-300/60"
              ]}
            >
              #{channel.name}
            </button>
          </nav>
          <div class="border-t border-base-300">
            <Layouts.settings_button />
          </div>
        </aside>

        <section class="relative flex min-w-0 flex-1 flex-col">
          <header
            :if={@current}
            class="border-b border-base-300 px-4 py-2 font-mono text-sm font-semibold"
          >
            #{@current.name}
            <span :if={@current.topic} class="ml-2 font-normal text-base-content/50">
              {@current.topic}
            </span>
          </header>

          <div
            id="messages"
            phx-update="stream"
            class="flex-1 space-y-0.5 overflow-y-auto px-4 py-3 font-mono text-sm"
          >
            <p id="messages-empty" class="hidden py-8 text-center text-base-content/40 only:block">
              No messages yet. Say hello.
            </p>
            <div
              :for={{dom_id, message} <- @streams.messages}
              id={dom_id}
              class={[
                "group/msg leading-relaxed",
                mentions?(message.body, @nick) && "-mx-2 rounded bg-primary/10 px-2"
              ]}
            >
              <button
                :if={message.reply_to}
                type="button"
                id={"#{dom_id}-jump"}
                phx-hook=".JumpToReply"
                data-target-id={"messages-#{message.reply_to.id}"}
                class="ml-14 flex items-center gap-1 text-[0.7rem] text-base-content/40 hover:text-base-content/70 hover:underline"
              >
                <.icon name="hero-arrow-uturn-left" class="size-3 shrink-0" />
                <span class={["font-semibold", nick_color(message.reply_to.nick)]}>
                  {message.reply_to.nick}
                </span>
                <span class="truncate">{reply_preview(message.reply_to.body)}</span>
              </button>

              <time class="mr-2 text-[0.7rem] text-base-content/30">
                {Calendar.strftime(message.inserted_at, "%H:%M")}
              </time>
              <%= if message.kind == "emote" do %>
                <span class={["italic", nick_color(message.nick)]}>
                  * {message.nick} {mention_html(message.body, @nick)}
                </span>
              <% else %>
                <span class={["font-semibold", nick_color(message.nick)]}>{message.nick}</span>
                <span class="text-base-content/40">:</span>
                <span class="whitespace-pre-wrap break-words">{mention_html(message.body, @nick)}</span>
              <% end %>
              <button
                type="button"
                phx-click="reply"
                phx-value-id={message.id}
                class="ml-1 rounded px-1 align-middle text-[0.7rem] text-base-content/30 opacity-60 transition-opacity hover:text-primary hover:opacity-100 md:opacity-0 md:group-hover/msg:opacity-100"
              >
                reply
              </button>
            </div>
          </div>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".JumpToReply">
            export default {
              mounted() {
                this.el.addEventListener("click", () => {
                  const target = document.getElementById(this.el.dataset.targetId)
                  if (!target) return

                  target.scrollIntoView({behavior: "smooth", block: "center"})
                  target.classList.add("message-highlight")
                  target.addEventListener(
                    "animationend",
                    () => target.classList.remove("message-highlight"),
                    {once: true}
                  )
                })
              }
            }
          </script>

          <div class="border-t border-base-300 p-3">
            <div
              :if={@replying_to}
              class="mb-2 flex items-center gap-2 rounded border border-base-300 bg-base-200/60 px-3 py-1.5 font-mono text-xs"
            >
              <.icon name="hero-arrow-uturn-left" class="size-3 shrink-0 text-base-content/40" />
              <span class="text-base-content/50">replying to</span>
              <span class={["font-semibold", nick_color(@replying_to.nick)]}>
                {@replying_to.nick}
              </span>
              <span class="flex-1 truncate text-base-content/50">
                {reply_preview(@replying_to.body)}
              </span>
              <button
                type="button"
                phx-click="cancel_reply"
                class="text-base-content/40 hover:text-base-content"
                aria-label="Cancel reply"
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </button>
            </div>
            <.form for={@msg_form} phx-submit="send" class="flex gap-2">
              <div class="relative flex-1">
                <div
                  id="command-suggestions"
                  phx-update="ignore"
                  class="absolute inset-x-0 bottom-full z-20 mb-1 hidden overflow-hidden rounded-lg border border-base-300 bg-base-100 shadow-lg"
                >
                </div>
                <input
                  type="text"
                  id="chat-body"
                  name="chat[body]"
                  value={@msg_form[:body].value}
                  autocomplete="off"
                  maxlength="2000"
                  phx-hook=".ChatInput"
                  phx-mounted={JS.focus()}
                  placeholder={
                    if @nick,
                      do: "message #" <> ((@current && @current.name) || ""),
                      else: "set a nick to talk"
                  }
                  disabled={is_nil(@nick)}
                  class="w-full rounded border border-base-300 bg-base-100 px-3 py-1.5 font-mono text-sm focus:border-primary focus:outline-none disabled:opacity-50"
                />
              </div>
              <button
                type="submit"
                disabled={is_nil(@nick)}
                class="rounded bg-primary px-3 py-1.5 text-sm font-semibold text-primary-content disabled:opacity-50"
              >
                Send
              </button>
            </.form>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".ChatInput">
              export default {
                commands: [
                  {name: "join", alias: "j", hint: "#channel", desc: "switch or create a channel"},
                  {name: "nick", alias: "n", hint: "name", desc: "change your nick"},
                  {name: "me", alias: null, hint: "action", desc: "send an action message"},
                  {name: "help", alias: null, hint: "", desc: "list commands"}
                ],
                mounted() {
                  this.menu = document.getElementById("command-suggestions")
                  this.matches = []
                  this.active = 0

                  this.onGlobalKeydown = (e) => {
                    if (this.el.disabled || this.el === document.activeElement) return
                    if (e.ctrlKey || e.metaKey || e.altKey || e.key.length !== 1) return

                    const active = document.activeElement
                    const active_is_field =
                      active &&
                      (active.tagName === "INPUT" || active.tagName === "TEXTAREA" || active.isContentEditable)
                    if (active_is_field) return

                    this.el.focus()
                  }
                  window.addEventListener("keydown", this.onGlobalKeydown)

                  this.onRecompute = () => this.updateMatches()
                  this.el.addEventListener("input", this.onRecompute)
                  this.el.addEventListener("keyup", this.onRecompute)
                  this.el.addEventListener("click", this.onRecompute)

                  this.onKeydown = (e) => {
                    if (this.matches.length === 0) return

                    if (e.key === "ArrowDown") {
                      e.preventDefault()
                      this.active = (this.active + 1) % this.matches.length
                      this.render()
                    } else if (e.key === "ArrowUp") {
                      e.preventDefault()
                      this.active = (this.active - 1 + this.matches.length) % this.matches.length
                      this.render()
                    } else if (e.key === "Tab" || e.key === "Enter") {
                      e.preventDefault()
                      this.apply(this.matches[this.active])
                    } else if (e.key === "Escape") {
                      this.hide()
                    }
                  }
                  this.el.addEventListener("keydown", this.onKeydown)

                  this.onBlur = () => setTimeout(() => this.hide(), 150)
                  this.el.addEventListener("blur", this.onBlur)
                },
                updateMatches() {
                  const commandMatch = this.el.value.match(/^\/([a-zA-Z]*)$/)

                  if (commandMatch) {
                    const query = commandMatch[1].toLowerCase()
                    this.range = {start: 0, end: this.el.value.length}
                    this.matches = this.commands
                      .filter(c => c.name.startsWith(query) || (c.alias && c.alias.startsWith(query)))
                      .map(c => ({label: `/${c.name}`, hint: c.hint, desc: c.desc, replacement: `/${c.name} `}))
                    this.active = 0
                    this.render()
                    return
                  }

                  const mention = this.mentionQuery()

                  if (mention) {
                    this.range = mention.range
                    this.matches = this.onlineNicks()
                      .filter(nick => nick.toLowerCase().startsWith(mention.query.toLowerCase()))
                      .slice(0, 8)
                      .map(nick => ({label: `@${nick}`, hint: "", desc: "", replacement: `@${nick} `}))
                    this.active = 0
                    this.render()
                    return
                  }

                  this.hide()
                },
                mentionQuery() {
                  const pos = this.el.selectionStart
                  const uptoCaret = this.el.value.slice(0, pos)
                  const match = uptoCaret.match(/(?:^|\s)@([A-Za-z0-9_\-\[\]\\^`{}|]{0,24})$/)
                  if (!match) return null

                  return {query: match[1], range: {start: uptoCaret.lastIndexOf("@"), end: pos}}
                },
                onlineNicks() {
                  return Array.from(document.querySelectorAll("#online-users li[data-nick]")).map(
                    el => el.dataset.nick
                  )
                },
                apply(match) {
                  const {start, end} = this.range
                  const value = this.el.value
                  const newValue = value.slice(0, start) + match.replacement + value.slice(end)
                  const newPos = start + match.replacement.length

                  this.el.value = newValue
                  this.hide()
                  this.el.focus()
                  this.el.setSelectionRange(newPos, newPos)
                },
                render() {
                  if (this.matches.length === 0) {
                    this.hide()
                    return
                  }

                  this.menu.innerHTML = ""
                  this.matches.forEach((match, i) => {
                    const item = document.createElement("button")
                    item.type = "button"
                    item.className =
                      "flex w-full items-center gap-2 px-3 py-1.5 text-left font-mono text-xs " +
                      (i === this.active
                        ? "bg-primary/10 text-primary"
                        : "text-base-content/70 hover:bg-base-300/60")
                    item.innerHTML =
                      `<span class="font-semibold">${match.label}</span>` +
                      (match.hint ? `<span class="text-base-content/40">${match.hint}</span>` : "") +
                      (match.desc ? `<span class="ml-auto text-base-content/40">${match.desc}</span>` : "")
                    item.addEventListener("mousedown", (e) => {
                      e.preventDefault()
                      this.apply(match)
                    })
                    this.menu.appendChild(item)
                  })
                  this.menu.classList.remove("hidden")
                },
                hide() {
                  this.matches = []
                  this.menu.classList.add("hidden")
                  this.menu.innerHTML = ""
                },
                destroyed() {
                  window.removeEventListener("keydown", this.onGlobalKeydown)
                  this.el.removeEventListener("input", this.onRecompute)
                  this.el.removeEventListener("keyup", this.onRecompute)
                  this.el.removeEventListener("click", this.onRecompute)
                  this.el.removeEventListener("keydown", this.onKeydown)
                  this.el.removeEventListener("blur", this.onBlur)
                }
              }
            </script>
          </div>

          <div
            :if={is_nil(@nick)}
            class="absolute inset-0 flex items-center justify-center bg-base-100/80 px-4 backdrop-blur-sm"
          >
            <.form
              for={@nick_form}
              phx-submit="set_nick"
              class="w-full max-w-72 space-y-3 rounded-lg border border-base-300 bg-base-100 p-5 shadow-lg"
            >
              <h2 class="font-mono text-sm font-semibold">Pick a nick</h2>
              <input
                type="text"
                name="join[nick]"
                value={@nick_form[:nick].value}
                autocomplete="off"
                autofocus
                placeholder="nick"
                class="w-full rounded border border-base-300 bg-base-100 px-3 py-1.5 font-mono text-sm focus:border-primary focus:outline-none"
              />
              <button
                type="submit"
                class="w-full rounded bg-primary px-3 py-1.5 text-sm font-semibold text-primary-content"
              >
                Join
              </button>
            </.form>
          </div>
        </section>

        <aside class={[
          "w-56 shrink-0 flex-col overflow-y-auto border-l border-base-300 bg-base-100 md:static md:z-auto md:flex md:w-48 md:bg-base-200/50",
          if(@mobile_panel == :online, do: "fixed inset-y-0 right-0 z-40 flex", else: "hidden")
        ]}>
          <div class="flex items-center justify-between px-3 py-2">
            <p class="truncate text-[0.7rem] font-semibold uppercase tracking-wider text-base-content/40">
              Online
              <span :if={@current} class="normal-case text-base-content/30">in #{@current.name}</span>
            </p>
            <button
              type="button"
              phx-click="close_mobile_panel"
              class="text-base-content/40 hover:text-base-content md:hidden"
              aria-label="Close"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <ul id="online-users" class="flex-1 overflow-y-auto px-3 pb-2 font-mono text-sm">
            <li
              :for={nick <- online_users_for(@online_users, @current)}
              data-nick={nick}
              class="flex items-center gap-1.5 truncate py-1"
            >
              <span class={[
                "size-1.5 shrink-0 rounded-full",
                if(nick == @nick, do: "bg-primary", else: "bg-success")
              ]} />
              <span class={[
                "truncate",
                nick == @nick && "font-semibold text-primary",
                nick != @nick && "text-base-content/70"
              ]}>
                {nick}
              </span>
            </li>
            <li
              :if={online_users_for(@online_users, @current) == []}
              class="py-1 text-base-content/40"
            >
              nobody here yet
            </li>
          </ul>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  @colors ~w(
    text-red-500 text-orange-500 text-amber-500 text-lime-600 text-emerald-500
    text-teal-500 text-sky-500 text-indigo-500 text-violet-500 text-fuchsia-500 text-rose-500
  )

  defp nick_color(nick) do
    Enum.at(@colors, :erlang.phash2(nick, length(@colors)))
  end

  defp reply_preview(body) do
    if String.length(body) > 80, do: String.slice(body, 0, 80) <> "…", else: body
  end
end
