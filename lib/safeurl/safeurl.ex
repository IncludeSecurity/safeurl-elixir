defmodule SafeURL do
  @moduledoc """
  `SafeURL` is library for mitigating Server Side Request
  Forgery vulnerabilities in Elixir. Private/reserved IP
  addresses are blocked by default, and users can add
  additional CIDR ranges to the blocklist, or alternatively
  allow specific CIDR ranges to which the application is
  allowed to make requests.

  You can use `allowed?/2` or `validate/2` to check if a
  URL is safe to call.


  ## Examples

      iex> SafeURL.allowed?("https://includesecurity.com")
      true

      iex> SafeURL.validate("http://google.com/", schemes: ~w[https])
      {:error, :unsafe_scheme}

      iex> SafeURL.validate("http://230.10.10.10/")
      {:error, :unsafe_reserved}

      iex> SafeURL.validate("http://230.10.10.10/", block_reserved: false)
      :ok

      # If HTTPoison is available:

      iex> SafeURL.HTTPoison.get("https://10.0.0.1/ssrf.txt")
      {:error, :unsafe_reserved}

      iex> SafeURL.HTTPoison.get("https://google.com/")
      {:ok, %HTTPoison.Response{...}}


  ## Options

  `SafeURL` can be configured to customize and override
  validation behaviour by passing the following options:

    * `:block_reserved` - Block reserved/private IP ranges.
      Defaults to `true`.

    * `:blocklist` - List of CIDR ranges to block. This is
      additive with `:block_reserved`. Defaults to `[]`.

    * `:allowlist` - List of CIDR ranges to allow. If
      specified, blocklist will be ignored. Defaults to `[]`.

    * `:schemes` - List of allowed URL schemes. Defaults to
      `["http, "https"]`.

    * `:dns_module` - Any module that implements the
      `SafeURL.DNSResolver` behaviour. Defaults to `DNS` from
      the `:dns` package.

    * `:detailed_error` - Return specific error if validation fails. If set to
      `false`, `validate/2` will return `{:error, :restricted}` regardless of
      the reason. Defaults to `true`.


  If `:block_reserved` is `true` and additional hosts/ranges
  are supplied with `:blocklist`, both of them are included in
  the final blocklist to validate the address. If allowed
  ranges are supplied with `:allowlist`, all blocklists are
  ignored and any hosts not explicitly declared in the allowlist
  are rejected.

  These options can be set globally in your `config.exs` file:

      config :safeurl,
        block_reserved: true,
        blocklist: ~w[100.0.0.0/16],
        schemes: ~w[https],
        dns_module: MyCustomDNSResolver

  Or they can be passed to the function directly, overriding any
  global options if set:

      iex> SafeURL.validate("http://10.0.0.1/", block_reserved: false)
      :ok

      iex> SafeURL.validate("https://app.service/", allowlist: ~w[170.0.0.0/24])
      :ok

      iex> SafeURL.validate("https://app.service/", blocklist: ~w[170.0.0.0/24])
      {:error, :unsafe_blocklist}

  """

  @reserved_ranges [
    "0.0.0.0/8",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.0.0.0/29",
    "192.0.2.0/24",
    "192.88.99.0/24",
    "192.168.0.0/16",
    "198.18.0.0/15",
    "198.51.100.0/24",
    "203.0.113.0/24",
    "224.0.0.0/4",
    "240.0.0.0/4"
  ]

  @type error() :: :unsafe_scheme | :unsafe_allowlist | :unsafe_blocklist | :unsafe_reserved

  # Public API
  # ----------

  @doc """
  Validate a string URL against a blocklist or allowlist.

  This method checks if a URL is safe to be called by looking at
  its scheme and resolved IP address, and matching it against
  reserved CIDR ranges, and any provided allowlist/blocklist.

  Returns `true` if the URL meets the requirements,
  `false` otherwise.

  ## Examples

      iex> SafeURL.allowed?("https://includesecurity.com")
      true

      iex> SafeURL.allowed?("http://10.0.0.1/")
      false

      iex> SafeURL.allowed?("http://10.0.0.1/", allowlist: ~w[10.0.0.0/8])
      true

  ## Options

  See [`Options`](#module-options) section above.

  """
  @spec allowed?(binary(), Keyword.t()) :: boolean()
  def allowed?(url, opts \\ []) do
    case validate(url, opts) do
      :ok -> true
      {:error, _} -> false
    end
  end

  @doc """
  Alternative method of validating a URL, returning result tuple instead
  of booleans.

  This calls `allowed?/2` underneath to check if a URL is safe to
  be called. If it is, it returns `:ok`, otherwise an error tuple with a
  specific reason. If `:detailed_error` is set to `false`, the error is always
  `{:error, :restricted}`.

  ## Examples

      iex> SafeURL.validate("https://includesecurity.com")
      :ok

      iex> SafeURL.validate("http://10.0.0.1/")
      {:error, :unsafe_reserved}

      iex> SafeURL.validate("http://10.0.0.1/", allowlist: ~w[10.0.0.0/8])
      :ok

  ## Options

  See [`Options`](#module-options) section above.

  """
  @spec validate(binary(), Keyword.t()) :: :ok | {:error, error()} | {:error, :restricted}
  def validate(url, opts \\ []) do
    uri = URI.parse(url)
    opts = build_options(opts)
    address = resolve_address(uri.host, opts.dns_module)

    result =
      cond do
        uri.scheme not in opts.schemes ->
          {:error, :unsafe_scheme}

        opts.allowlist != [] ->
          if ip_in_ranges?(address, opts.allowlist), do: :ok, else: {:error, :unsafe_allowlist}

        opts.blocklist != [] and ip_in_ranges?(address, opts.blocklist) ->
          {:error, :unsafe_blocklist}

        opts.block_reserved and ip_in_ranges?(address, @reserved_ranges) ->
          {:error, :unsafe_reserved}

        true ->
          :ok
      end

    with {:error, _} <- result do
      if opts.detailed_error, do: result, else: {:error, :restricted}
    end
  end

  # Private Helpers
  # ---------------

  # Return a map of calculated options
  defp build_options(opts) do
    schemes = get_option(opts, :schemes)
    allowlist = get_option(opts, :allowlist)
    blocklist = get_option(opts, :blocklist)
    dns_module = get_option(opts, :dns_module)
    block_reserved = get_option(opts, :block_reserved)
    detailed_error = get_option(opts, :detailed_error)

    %{
      schemes: schemes,
      allowlist: allowlist,
      blocklist: blocklist,
      dns_module: dns_module,
      block_reserved: block_reserved,
      detailed_error: detailed_error
    }
  end

  # Get the value of a specific option, either from the application
  # configs or overrides explicitly passed as arguments.
  defp get_option(opts, key),
    do: Keyword.get_lazy(opts, key, fn -> Application.get_env(:safeurl, key) end)

  # Resolve hostname in DNS to an IP address (if not already an IP)
  defp resolve_address(hostname, dns_module) do
    hostname
    |> to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} ->
        ip

      {:error, :einval} ->
        # TODO: safely handle multiple IPs/round-robin DNS
        case dns_module.resolve(hostname) do
          {:ok, [ip | _]} -> ip
          {:error, _reason} -> nil
        end
    end
  end

  defp ip_in_ranges?({_, _, _, _} = addr, ranges) when is_list(ranges) do
    Enum.any?(ranges, fn range ->
      range
      |> InetCidr.parse_cidr!()
      |> InetCidr.contains?(addr)
    end)
  end

  defp ip_in_ranges?(_addr, _ranges), do: false
end
