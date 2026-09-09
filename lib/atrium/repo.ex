defmodule Atrium.Repo do
  use Ecto.Repo,
    otp_app: :atrium,
    adapter: Ecto.Adapters.SQLite3
end
