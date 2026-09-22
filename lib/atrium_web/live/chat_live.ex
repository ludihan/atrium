defmodule AtriumWeb.ChatLive do
  @moduledoc """
  The whole app: a nick prompt, a list of channels down the side, and one
  message pane.
  """
  use AtriumWeb, :live_view

  alias Atrium.Chat

  @blocked_notice_ttl :timer.seconds(4)

  @impl true
  def mount(_params, _session, socket) do
    channels = Chat.list_channels()
    current = Enum.find(channels, &(&1.name == "general")) || List.first(channels)

    if connected?(socket) do
      Chat.subscribe_directory()
      if current, do: Chat.subscribe(current)
    end

    socket =
      socket
      |> assign(:page_title, "atrium")
      |> assign(:nick, nil)
      |> assign(:channels, channels)
      |> assign(:current, current)
      |> assign(:nick_form, to_form(%{"nick" => ""}, as: :join))
      |> assign(:msg_form, to_form(%{"body" => ""}, as: :chat))
      |> stream(:messages, (current && Chat.list_recent_messages(current)) || [], limit: -100)
      |> stream(:blocked_notices, [])

    {:ok, socket}
  end

  @impl true
  def handle_event("set_nick", %{"join" => %{"nick" => nick}}, socket) do
    case sanitize_nick(nick) do
      "" ->
        {:noreply, put_flash(socket, :error, "Pick a nick with letters or numbers.")}

      nick ->
        {:noreply, assign(socket, :nick, nick)}
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
    {:noreply, stream_delete(socket, :blocked_notices, %{id: id})}
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
      "" -> put_flash(socket, :error, "Usage: /nick <name>")
      nick -> clear_input(assign(socket, :nick, nick))
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
    case Chat.post_message(socket.assigns.current, socket.assigns.nick, body, kind) do
      {:ok, _message} ->
        clear_input(socket)

      {:error, :moderated} ->
        show_blocked_notice(socket, "Message blocked: breaks the channel rules.")

      {:error, _changeset} ->
        put_flash(socket, :error, "Message was not sent.")
    end
  end

  defp show_blocked_notice(socket, text) do
    id = "blocked-#{System.unique_integer([:positive, :monotonic])}"
    Process.send_after(self(), {:dismiss_blocked_notice, id}, @blocked_notice_ttl)
    stream_insert(socket, :blocked_notices, %{id: id, text: text}, at: 0)
  end

  defp switch_channel(socket, channel) do
    if socket.assigns.current && socket.assigns.current.id == channel.id do
      clear_input(socket)
    else
      if connected?(socket) do
        if socket.assigns.current, do: Chat.unsubscribe(socket.assigns.current)
        Chat.subscribe(channel)
      end

      socket
      |> assign(:current, channel)
      |> clear_input()
      |> stream(:messages, Chat.list_recent_messages(channel), reset: true)
    end
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

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <:header>
        <span :if={@nick} class="font-mono text-xs text-base-content/70">
          you are <span class="font-semibold text-base-content">{@nick}</span>
        </span>
      </:header>

      <div
        id="blocked-notices"
        phx-update="stream"
        class="pointer-events-none fixed inset-x-0 top-3 z-50 flex flex-col items-center gap-2 px-4"
      >
        <div
          :for={{dom_id, notice} <- @streams.blocked_notices}
          id={dom_id}
          phx-remove={hide("##{dom_id}")}
          class="pointer-events-auto rounded-md border border-error/30 bg-error px-3 py-1.5 font-mono text-xs font-medium text-error-content shadow-lg"
        >
          {notice.text}
        </div>
      </div>

      <div class="flex h-full min-h-0">
        <aside class="flex w-44 shrink-0 flex-col border-r border-base-300 bg-base-200/50">
          <p class="px-3 py-2 text-[0.7rem] font-semibold uppercase tracking-wider text-base-content/40">
            Channels
          </p>
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
          <p class="border-t border-base-300 px-3 py-2 font-mono text-[0.7rem] text-base-content/40">
            /join #newroom
          </p>
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
            <div :for={{dom_id, message} <- @streams.messages} id={dom_id} class="leading-relaxed">
              <time class="mr-2 text-[0.7rem] text-base-content/30">
                {Calendar.strftime(message.inserted_at, "%H:%M")}
              </time>
              <%= if message.kind == "emote" do %>
                <span class={["italic", nick_color(message.nick)]}>
                  * {message.nick} {message.body}
                </span>
              <% else %>
                <span class={["font-semibold", nick_color(message.nick)]}>{message.nick}</span>
                <span class="text-base-content/40">:</span>
                <span class="whitespace-pre-wrap break-words">{message.body}</span>
              <% end %>
            </div>
          </div>

          <div class="border-t border-base-300 p-3">
            <.form for={@msg_form} phx-submit="send" class="flex gap-2">
              <input
                type="text"
                id="chat-body"
                name="chat[body]"
                value={@msg_form[:body].value}
                autocomplete="off"
                maxlength="2000"
                phx-mounted={JS.focus()}
                placeholder={
                  if @nick,
                    do: "message #" <> ((@current && @current.name) || ""),
                    else: "set a nick to talk"
                }
                disabled={is_nil(@nick)}
                class="flex-1 rounded border border-base-300 bg-base-100 px-3 py-1.5 font-mono text-sm focus:border-primary focus:outline-none disabled:opacity-50"
              />
              <button
                type="submit"
                disabled={is_nil(@nick)}
                class="rounded bg-primary px-3 py-1.5 text-sm font-semibold text-primary-content disabled:opacity-50"
              >
                Send
              </button>
            </.form>
          </div>

          <div
            :if={is_nil(@nick)}
            class="absolute inset-0 flex items-center justify-center bg-base-100/80 backdrop-blur-sm"
          >
            <.form
              for={@nick_form}
              phx-submit="set_nick"
              class="w-72 space-y-3 rounded-lg border border-base-300 bg-base-100 p-5 shadow-lg"
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
end
