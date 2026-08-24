defmodule Nicechat.Repo do
  use Ecto.Repo,
    otp_app: :nicechat,
    adapter: Ecto.Adapters.Postgres
end
