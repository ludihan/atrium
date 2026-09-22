defmodule Atrium.Chat.Message do
  @moduledoc "A single line said (or `/me` emoted) by a nick in a channel."
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(said emote)

  schema "messages" do
    field :body, :string
    field :nick, :string
    field :kind, :string, default: "said"

    belongs_to :channel, Atrium.Chat.Channel
    belongs_to :reply_to, Atrium.Chat.Message

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:body, :nick, :kind, :channel_id, :reply_to_id])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body, :nick, :channel_id])
    |> validate_length(:body, max: 2000)
    |> validate_inclusion(:kind, @kinds)
    |> assoc_constraint(:channel)
    |> assoc_constraint(:reply_to)
  end
end
