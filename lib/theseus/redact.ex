defmodule Theseus.Redact do
  @moduledoc """
  Removes secrets from data that came from outside the system before it is
  stored or shown: recorded calls, crash reports, shadow evidence and LLM
  prompts.

  A value is replaced with `"[redacted]"` when its key looks sensitive (map
  keys and the first element of two-element tuples, so keyword lists too).
  Inside strings, substrings that look like credentials or card numbers are
  replaced. Config:

      config :theseus, :redact,
        # Matched anywhere inside a key, ignoring case and punctuation.
        keys: ["password", "token", ...],
        # Regex sources, replaced inside every string.
        patterns: [~S"Bearer\s+\S+", ...],
        card_numbers: true

  Redaction changes recorded inputs, so a redacted call replays with the
  redacted value. That only narrows what replay covers.
  """

  @mark "[redacted]"

  @default_keys ~w(password passwd passphrase secret token apikey accesskey authorization
                   cookie privatekey clientsecret cardnumber creditcard cvv cvc ssn)

  @default_patterns [
    # Authorization headers
    "Bearer\\s+[A-Za-z0-9._~+/=-]+",
    "Basic\\s+[A-Za-z0-9+/=]{8,}",
    # API keys with well-known prefixes
    "\\bsk-[A-Za-z0-9_-]{16,}",
    "\\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}",
    "\\bAKIA[0-9A-Z]{16}\\b",
    "\\bxox[abprs]-[A-Za-z0-9-]{10,}",
    # Theseus's CSRF tokens
    "\\btcsrf_[A-Za-z0-9_-]{16,}",
    # JSON web tokens
    "\\beyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}",
    # Private keys
    "-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"
  ]

  @email ~r/\b([A-Za-z0-9._%+-]+)@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})\b/
  @name_field ~r/((?:"|\b)(?:first_|last_|full_|given_|family_|display_|requester_)?name"?(?::|\s*=>)\s*)"(?:[^"\\]|\\.)*"/

  @doc """
  Text with personal data replaced, for prompts that leave the machine:
  the part of each email address before the @ becomes a pseudonym that is
  the same wherever the address appears (the domain stays, since rules
  often depend on it), and quoted values of name fields (`name`,
  `first_name`, `"last_name" =>` and the like) become `"[name]"`.
  """
  @spec personal(String.t()) :: String.t()
  def personal(text) when is_binary(text) do
    text
    |> then(&Regex.replace(@name_field, &1, ~s(\\1"[name]")))
    |> then(
      &Regex.replace(@email, &1, fn _, local, domain ->
        "person-" <>
          Integer.to_string(:erlang.phash2(String.downcase(local), 65_536), 16) <> "@" <> domain
      end)
    )
  end

  @doc "The term with secrets replaced."
  @spec term(term()) :: term()
  def term(term), do: walk(term, config())

  defp walk(%{} = map, c) do
    map
    |> Map.to_list()
    |> Map.new(fn
      {:__struct__, mod} -> {:__struct__, mod}
      {k, v} -> if sensitive?(k, c), do: {k, @mark}, else: {k, walk(v, c)}
    end)
  end

  defp walk({k, v}, c) when is_atom(k) or is_binary(k) do
    if sensitive?(k, c), do: {k, @mark}, else: {k, walk(v, c)}
  end

  defp walk(tuple, c) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&walk(&1, c)) |> List.to_tuple()

  defp walk([head | tail], c), do: [walk(head, c) | walk_tail(tail, c)]
  defp walk(binary, c) when is_binary(binary), do: string(binary, c)
  defp walk(other, _c), do: other

  # Improper lists keep their tail.
  defp walk_tail([head | tail], c), do: [walk(head, c) | walk_tail(tail, c)]
  defp walk_tail([], _c), do: []
  defp walk_tail(other, c), do: walk(other, c)

  defp sensitive?(key, c) when is_atom(key) and key not in [nil, true, false],
    do: sensitive?(Atom.to_string(key), c)

  defp sensitive?(key, c) when is_binary(key) do
    normal = key |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
    Enum.any?(c.keys, &String.contains?(normal, &1))
  end

  defp sensitive?(_key, _c), do: false

  defp string(s, c) do
    if String.valid?(s) do
      s = if c.pattern, do: Regex.replace(c.pattern, s, @mark), else: s
      if c.cards, do: cards(s), else: s
    else
      s
    end
  end

  # 13 to 19 digits, optionally grouped by spaces or dashes, that pass the
  # Luhn check.
  defp cards(s) do
    Regex.replace(~r/\b\d(?:[ -]?\d){12,18}\b/, s, fn match ->
      digits = for <<d <- match>>, d in ?0..?9, do: d - ?0
      if luhn?(digits), do: @mark, else: match
    end)
  end

  defp luhn?(digits) do
    sum =
      digits
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce(0, fn
        {d, i}, acc when rem(i, 2) == 1 -> acc + if(d * 2 > 9, do: d * 2 - 9, else: d * 2)
        {d, _}, acc -> acc + d
      end)

    rem(sum, 10) == 0
  end

  # Compiled once per configuration and kept in persistent_term.
  defp config do
    settings = Application.get_env(:theseus, :redact, [])
    key = {__MODULE__, :erlang.phash2(settings)}

    case :persistent_term.get(key, nil) do
      nil ->
        patterns = Keyword.get(settings, :patterns, @default_patterns)

        compiled = %{
          keys: Keyword.get(settings, :keys, @default_keys),
          pattern:
            if(patterns == [],
              do: nil,
              else: Regex.compile!(Enum.map_join(patterns, "|", &"(?:#{&1})"))
            ),
          cards: Keyword.get(settings, :card_numbers, true)
        }

        :persistent_term.put(key, compiled)
        compiled

      compiled ->
        compiled
    end
  end
end
