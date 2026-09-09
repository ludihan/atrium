defmodule Atrium.Chat do
  @moduledoc """
  The chat context: channels and messages, persisted with SQLite and pushed to
  connected clients over `Phoenix.PubSub`.
  """

  import Ecto.Query, warn: false

  alias Atrium.Repo
  alias Atrium.Chat.{Channel, Message}

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
  end

  @doc """
  Records a line in `channel` and broadcasts it to everyone watching that
  channel. `kind` is `"said"` or `"emote"` (`/me`).
  """
  def post_message(%Channel{} = channel, nick, body, kind \\ "said") do
    %Message{}
    |> Message.changeset(%{body: body, nick: nick, kind: kind, channel_id: channel.id})
    |> Repo.insert()
    |> case do
      {:ok, message} ->
        Phoenix.PubSub.broadcast(@pubsub, topic(channel), {:new_message, message})
        {:ok, message}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

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
