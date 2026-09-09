defmodule Nicechat.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages) do
      add :body, :text, null: false
      add :nick, :string, null: false
      add :kind, :string, null: false, default: "said"
      add :channel_id, references(:channels, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:messages, [:channel_id])
    create index(:messages, [:channel_id, :inserted_at])
  end
end
