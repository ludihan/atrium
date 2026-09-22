defmodule Atrium.Chat.Moderation do
  @moduledoc """
  Optional message moderation backed by the TypeSafe Jev API.

  Enabled only when both `JEV_API_KEY` and `CHAT_RULES` are configured (see
  `config/runtime.exs`); if either is missing, every message is allowed.
  Any API failure also fails open, so a misconfigured or unreachable
  moderation service never blocks the chat itself.

  A message that trips `breaks_rules` isn't blocked outright: `category` and
  `severity` are judged in the same request and used to decide whether it's
  merely a warning (posted, with the author quietly flagged) or a block.
  Missing or unparsable `category`/`severity` data also fails open to a
  warning rather than a block, for the same never-block-on-a-hiccup reason.
  """

  require Logger

  @endpoint "https://api.typesafe.ai/v1/systemone"
  @breaks_rules_threshold 0.5
  @severe_threshold 1.5

  @doc "Whether moderation is configured (an API key and rules are both set)."
  def enabled? do
    config = Application.get_env(:atrium, :moderation, [])
    !!config[:jev_api_key] and !!config[:rules]
  end

  @doc """
  Checks `body` against the configured rules.

  Returns `:allow`, `{:warn, meta}`, or `{:block, meta}`, where `meta` is
  `%{category: string, severity: string}`. Always returns `:allow` when
  moderation is disabled or the API call fails.
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
        },
        category: %{
          type: "choice",
          instructions:
            "Given the channel `rules`, which category best fits why the `message` might violate them?",
          criteria: %{
            spam: "Repetitive, promotional, or flooding content unrelated to the conversation",
            harassment: "Insults, threats, or targeted hostility toward a person or group",
            off_topic: "Breaks a rule about staying on topic for the channel",
            other: "Violates a rule not covered by the other categories",
            none: "Does not violate any of the rules"
          }
        },
        severity: %{
          type: "score",
          instructions:
            "Given the channel `rules`, how severe would the `message` be if it violates them?",
          criteria: [
            "Mild: a borderline or minor issue, unlikely to bother anyone",
            "Moderate: a clear violation, but not harmful or abusive",
            "Severe: a harmful, abusive, or otherwise serious violation"
          ]
        }
      }
    }

    opts =
      [json: payload, auth: {:bearer, api_key}, receive_timeout: 5_000] ++ req_test_opts()

    case Req.post(@endpoint, opts) do
      {:ok, %Req.Response{status: 200, body: %{"answers" => answers}}} ->
        decide(answers)

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

  defp decide(%{"breaks_rules" => %{"noul" => breaks_score}} = answers)
       when breaks_score >= @breaks_rules_threshold do
    meta = %{
      category: get_in(answers, ["category", "choice"]) || "other",
      severity: severity_label(answers["severity"])
    }

    if severity_score(answers["severity"]) >= @severe_threshold do
      {:block, meta}
    else
      {:warn, meta}
    end
  end

  defp decide(%{"breaks_rules" => %{"noul" => _}}), do: :allow

  defp decide(answers) do
    Logger.warning("Atrium.Chat.Moderation: unexpected answers shape: #{inspect(answers)}")
    :allow
  end

  defp severity_score(%{"score" => score}) when is_number(score), do: score
  defp severity_score(_), do: 0.0

  defp severity_label(%{"score" => score, "legend" => legend}) when is_number(score) do
    level = score |> Float.round() |> trunc() |> max(0)
    Map.get(legend, to_string(level), "moderate")
  end

  defp severity_label(_), do: "moderate"

  # Lets tests swap in a `Req.Test` stub via `config :atrium, :moderation, plug: ...`
  # instead of hitting the real TypeSafe API.
  defp req_test_opts do
    case Application.get_env(:atrium, :moderation, [])[:plug] do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
