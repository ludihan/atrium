# Run with: mix run priv/repo/seeds.exs (or `mix ecto.setup`)
#
# Seeds the default channels every atrium address starts with.

for name <- ~w(general random dev) do
  Atrium.Chat.get_or_create_channel(name)
end
