defmodule Atrium.Chat do
  @moduledoc """
  The chat context: channels and messages, persisted with SQLite and pushed to
  connected clients over `Phoenix.PubSub`.
  """

  import Ecto.Query, warn: false

  alias Atrium.Repo
  alias Atrium.Chat.{Channel, Message, Moderation}

  @pubsub Atrium.PubSub
  @recent_limit 100

  ## Channels

  @doc "All channels, ordered by name."
  def list_channels do
    Repo.all(from c in Channel, order_by: c.name)
  end

  def get_channel!(id), do: Repo.get!(Channel, id)

  def get_channel_by_name(name) do
    Repo.get_by(Channel, name: Channel.normalize_name(name))
  end

  @doc """
  Fetches the channel named `name`, creating it on first use (that is what
  `/join` does on IRC).
  """
  def get_or_create_channel(name) do
    case get_channel_by_name(name) do
      %Channel{} = channel ->
        {:ok, channel}

      nil ->
        %Channel{}
        |> Channel.changeset(%{name: name})
        |> Repo.insert()
        |> case do
          {:ok, channel} ->
            broadcast_channels()
            {:ok, channel}

          {:error, changeset} ->
            # A concurrent joiner may have created it between our lookup and
            # insert; treat that as success. Anything else is a real error.
            case get_channel_by_name(name) do
              %Channel{} = channel -> {:ok, channel}
              nil -> {:error, changeset}
            end
        end
    end
  end

  ## Messages

  @doc "The most recent messages in `channel`, oldest first."
  def list_recent_messages(%Channel{id: channel_id}, limit \\ @recent_limit) do
    from(m in Message,
      where: m.channel_id == ^channel_id,
      order_by: [desc: m.inserted_at, desc: m.id],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.reverse()
    |> Repo.preload(:reply_to)
  end

  @doc "Fetches a message by id, or `nil` if it does not exist."
  def get_message(id), do: Repo.get(Message, id)

  @doc """
  Records a line in `channel` and broadcasts it to everyone watching that
  channel. `kind` is `"said"` or `"emote"` (`/me`).

  `reply_to` is an optional `%Message{}` this line responds to; it is only
  attached when it belongs to the same `channel` (silently dropped otherwise).

  When moderation is configured (see `Atrium.Chat.Moderation`), the message is
  checked against the configured rules first. A severe violation is rejected
  with `{:error, {:moderated, meta}}` instead of being stored; a milder one is
  still stored and returned as `{:ok, message, {:warn, meta}}` so the caller
  can flag it to the author. `meta` is `%{category: string, severity: string}`.
  """
  def post_message(%Channel{} = channel, nick, body, kind \\ "said", reply_to \\ nil) do
    case Moderation.check(body) do
      {:block, meta} ->
        {:error, {:moderated, meta}}

      warn_or_allow ->
        attrs = %{
          body: body,
          nick: nick,
          kind: kind,
          channel_id: channel.id,
          reply_to_id: reply_to_id(reply_to, channel)
        }

        %Message{}
        |> Message.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, message} ->
            message = Repo.preload(message, :reply_to)
            Phoenix.PubSub.broadcast(@pubsub, topic(channel), {:new_message, message})

            case warn_or_allow do
              {:warn, meta} -> {:ok, message, {:warn, meta}}
              :allow -> {:ok, message}
            end

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  defp reply_to_id(%Message{id: id, channel_id: channel_id}, %Channel{id: channel_id}), do: id
  defp reply_to_id(_reply_to, _channel), do: nil

  ## PubSub

  @doc "Subscribe to new messages in a channel."
  def subscribe(%Channel{} = channel), do: Phoenix.PubSub.subscribe(@pubsub, topic(channel))
  def unsubscribe(%Channel{} = channel), do: Phoenix.PubSub.unsubscribe(@pubsub, topic(channel))

  @doc "Subscribe to the channel list changing (new channels created)."
  def subscribe_directory, do: Phoenix.PubSub.subscribe(@pubsub, "chat:directory")

  defp broadcast_channels do
    Phoenix.PubSub.broadcast(@pubsub, "chat:directory", {:channels, list_channels()})
  end

  defp topic(%Channel{id: id}), do: "chat:channel:#{id}"
end
