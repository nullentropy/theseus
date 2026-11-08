defmodule Theseus.PageText do
  @moduledoc """
  What a person reads on an HTML page an endpoint unit returned: its title
  and its visible text, without markup, styles or scripts. Used to show how
  two pages differ, and to tell differences in text from differences in
  markup or styling only.
  """

  @doc "The page's title, unescaped, or nil."
  @spec title(String.t()) :: String.t() | nil
  def title(html) do
    case Regex.run(~r{<title>(.*?)</title>}s, html) do
      [_, title] -> unescape(title)
      _ -> nil
    end
  end

  @doc "The page's visible text, one entry per line."
  @spec lines(String.t()) :: [String.t()]
  def lines(html) do
    html
    |> String.replace(~r{<(script|style)[^>]*>.*?</\1>}s, "")
    |> String.replace(~r{<head>.*?</head>}s, "")
    |> String.replace(~r{<[^>]+>}, "\n")
    |> unescape()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Whether two results are pages (`{status, :html, html}` with the same
  status, or HTML a page unit returned) that differ only in styling: see
  `compare/2`.
  """
  @spec styling_only?(term(), term()) :: boolean()
  def styling_only?({:ok, {status, :html, a}}, {:ok, {status, :html, b}})
      when is_binary(a) and is_binary(b),
      do: compare(a, b) == :styling

  def styling_only?({:ok, a}, {:ok, b}) when is_binary(a) and is_binary(b),
    do: html?(a) and html?(b) and compare(a, b) == :styling

  def styling_only?({:ok, {:htmx, headers, a}}, {:ok, {:htmx, headers, b}}),
    do: styling_only?({:ok, a}, {:ok, b})

  def styling_only?(_before, _after), do: false

  @doc """
  How two pages differ:

    * `:same`
    * `:styling`: only classes, style attributes, `<style>` blocks or
      whitespace differ, so the page reads and works the same
    * `:markup`: the title and visible text are the same, but links, forms,
      scripts or other markup differ
    * `{:text, removed, added}`: the title or the visible text differs;
      `removed` and `added` are the visible lines only one side has, in
      order
  """
  @spec compare(String.t(), String.t()) ::
          :same | :styling | :markup | {:text, [String.t()], [String.t()]}
  def compare(a, a), do: :same

  def compare(a, b) do
    if normalize(a) == normalize(b) do
      :styling
    else
      {removed, added} = line_diff(lines(a), lines(b))

      if removed == [] and added == [] and title(a) == title(b),
        do: :markup,
        else: {:text, removed, added}
    end
  end

  defp normalize(html) do
    html
    |> String.replace(~r{<style[^>]*>.*?</style>}is, "")
    |> String.replace(~r{\s(?:class|style)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)}i, "")
    |> String.replace(~r{\s+}, " ")
    |> String.replace(~r{\s*([<>])\s*}, "\\1")
  end

  # Pages are compared on their first 1000 visible lines.
  defp line_diff(a, b) do
    List.myers_difference(Enum.take(a, 1000), Enum.take(b, 1000))
    |> Enum.reduce({[], []}, fn
      {:del, lines}, {removed, added} -> {removed ++ lines, added}
      {:ins, lines}, {removed, added} -> {removed, added ++ lines}
      {:eq, _lines}, acc -> acc
    end)
  end

  @doc "Whether text looks like HTML: it has a tag."
  @spec html?(String.t()) :: boolean()
  def html?(text), do: Regex.match?(~r{<(!doctype|[a-z][a-z0-9]*)[\s>/]}i, text)

  @doc "Text with the five HTML entities Plug.HTML writes turned back."
  @spec unescape(String.t()) :: String.t()
  def unescape(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end
end
