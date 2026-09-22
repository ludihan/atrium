defmodule Atrium.Chat.Moderation do
  @moduledoc """
  Optional message moderation backed by the TypeSafe Jev API.

  Enabled only when both `JEV_API_KEY` and `CHAT_RULES` are configured (see
  `config/runtime.exs`); if either is missing, every message is allowed.
  Any API failure also fails open, so a misconfigured or unreachable
  moderation service never blocks the chat itself.
  """

  require Logger

  @endpoint "https://api.typesafe.ai/v1/systemone"

  @doc "Whether moderation is configured (an API key and rules are both set)."
  def enabled? do
    config = Application.get_env(:atrium, :moderation, [])
    !!config[:jev_api_key] and !!config[:rules]
  end

  @doc """
  Checks `body` against the configured rules, returning `:allow` or `:block`.
  Always returns `:allow` when moderation is disabled or the API call fails.
  """
  def check(body) do
    config = Application.get_env(:atrium, :moderation, [])

    if enabled?() do
      request(body, config[:jev_api_key], config[:rules])
    else
      :allow
    end
  end

  defp request(body, api_key, rules) do
    payload = %{
      model: "jev-latest",
      state: %{message: body, rules: rules},
      questions: %{
        breaks_rules: %{
          type: "noul",
          instructions: "Given the channel `rules`, does the chat `message` break any of them?",
          criteria: %{
            true: "The message clearly violates one or more of the rules",
            false: "The message does not violate any of the rules"
          }
        }
      }
    }

    opts =
      [json: payload, auth: {:bearer, api_key}, receive_timeout: 5_000] ++ req_test_opts()

    case Req.post(@endpoint, opts) do
      {:ok,
       %Req.Response{
         status: 200,
         body: %{"answers" => %{"breaks_rules" => %{"noul" => score}}}
       }} ->
        if score >= 0.5, do: :block, else: :allow

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        Logger.warning(
          "Atrium.Chat.Moderation: unexpected response #{status}: #{inspect(resp_body)}"
        )

        :allow

      {:error, reason} ->
        Logger.warning("Atrium.Chat.Moderation: request failed: #{inspect(reason)}")
        :allow
    end
  end

  # Lets tests swap in a `Req.Test` stub via `config :atrium, :moderation, plug: ...`
  # instead of hitting the real TypeSafe API.
  defp req_test_opts do
    case Application.get_env(:atrium, :moderation, [])[:plug] do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
