# Run with: mix run priv/repo/seeds.exs (or `mix ecto.setup`)
#
# Seeds the default channels every nicechat address starts with.

for name <- ~w(general random dev) do
  Nicechat.Chat.get_or_create_channel(name)
end
