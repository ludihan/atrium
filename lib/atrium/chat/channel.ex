defmodule Atrium.Chat.Channel do
  @moduledoc "A named chat room."
  use Ecto.Schema
  import Ecto.Changeset

  schema "channels" do
    field :name, :string
    field :topic, :string

    has_many :messages, Atrium.Chat.Message

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:name, :topic])
    |> update_change(:name, &normalize_name/1)
    |> validate_required([:name])
    |> validate_format(:name, ~r/\A[a-z0-9][a-z0-9_-]{0,31}\z/,
      message: "may only contain lowercase letters, numbers, hyphens and underscores"
    )
    |> unique_constraint(:name)
  end

  @doc "Strips a leading `#` and lowercases, so `#General` and `general` are the same room."
  def normalize_name(nil), do: nil

  def normalize_name(name) do
    name |> String.trim() |> String.trim_leading("#") |> String.downcase()
  end
end
