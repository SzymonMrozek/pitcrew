defmodule BuildDistro.IPA do
  @moduledoc """
  Reads what a build page needs from an IPA: app identity and version, the
  provisioning profile and the icon. Only those entries are fetched.
  """

  alias BuildDistro.IPA.{Plist, PNG, Zip}

  @max_plist_size 2 * 1024 * 1024
  @max_icon_size 4 * 1024 * 1024
  @info_plist ~r{^Payload/[^/]+\.app/Info\.plist$}

  @type metadata :: %{
          bundle_id: String.t() | nil,
          version: String.t() | nil,
          build_version: String.t() | nil,
          display_name: String.t() | nil,
          minimum_os: String.t() | nil,
          profile: map() | nil,
          icon: binary() | nil
        }

  @doc """
  Inspects the IPA behind `reader`. Returns `{:error, {:invalid, reason}}` for
  files that will never succeed, and other errors for ones worth retrying.
  """
  @spec inspect_ipa(Zip.reader(), non_neg_integer()) ::
          {:ok, metadata()} | {:error, {:invalid, String.t()} | term()}
  def inspect_ipa(reader, size) do
    with {:ok, entries} <- entries(reader, size),
         {:ok, app_dir, info_entry} <- find_app(entries),
         {:ok, info} <- read_plist(reader, info_entry) do
      {:ok,
       %{
         bundle_id: string(info["CFBundleIdentifier"]),
         version: string(info["CFBundleShortVersionString"]),
         build_version: string(info["CFBundleVersion"]),
         display_name: string(info["CFBundleDisplayName"] || info["CFBundleName"]),
         minimum_os: string(info["MinimumOSVersion"]),
         profile: read_profile(reader, entries, app_dir),
         icon: read_icon(reader, entries, app_dir, info)
       }}
    end
  end

  defp entries(reader, size) do
    case Zip.entries(reader, size) do
      {:error, reason}
      when reason in [:not_a_zip, :bad_central_directory, :bad_zip64_directory] ->
        {:error, {:invalid, "The upload isn't a valid IPA (#{reason})."}}

      result ->
        result
    end
  end

  defp find_app(entries) do
    case Enum.filter(entries, &Regex.match?(@info_plist, &1.name)) do
      [entry] -> {:ok, Path.dirname(entry.name), entry}
      [] -> {:error, {:invalid, "The IPA has no Payload/*.app/Info.plist."}}
      _ -> {:error, {:invalid, "The IPA contains more than one app."}}
    end
  end

  defp read_plist(reader, entry) do
    with {:ok, data} <- Zip.read_entry(reader, entry, @max_plist_size) do
      case Plist.decode(data) do
        {:ok, %{} = plist} -> {:ok, plist}
        _ -> {:error, {:invalid, "Info.plist can't be read."}}
      end
    end
  end

  # A missing or unreadable profile doesn't fail the build: simulator and
  # enterprise builds can still be shown.
  defp read_profile(reader, entries, app_dir) do
    with %Zip.Entry{} = entry <- find(entries, app_dir <> "/embedded.mobileprovision"),
         {:ok, data} <- Zip.read_entry(reader, entry, @max_plist_size),
         {:ok, %{} = profile} <- Plist.decode_profile(data) do
      devices = List.wrap(profile["ProvisionedDevices"])

      %{
        "name" => string(profile["Name"]),
        "team" => string(profile["TeamName"]),
        "expires_at" => date(profile["ExpirationDate"]),
        "kind" => profile_kind(profile),
        "device_count" => length(devices),
        "devices" => devices
      }
    else
      _ -> nil
    end
  end

  defp profile_kind(%{"ProvisionsAllDevices" => true}), do: "enterprise"

  defp profile_kind(%{"ProvisionedDevices" => [_ | _]} = profile) do
    if get_in(profile, ["Entitlements", "get-task-allow"]) == true,
      do: "development",
      else: "ad-hoc"
  end

  defp profile_kind(_), do: "app-store"

  # The largest PNG among the icon files Info.plist names, which is the
  # highest resolution one.
  defp read_icon(reader, entries, app_dir, info) do
    names =
      [
        get_in(info, ["CFBundleIcons", "CFBundlePrimaryIcon", "CFBundleIconFiles"]),
        get_in(info, ["CFBundleIcons~ipad", "CFBundlePrimaryIcon", "CFBundleIconFiles"]),
        info["CFBundleIconFiles"],
        get_in(info, ["CFBundleIcons", "CFBundlePrimaryIcon", "CFBundleIconName"])
      ]
      |> Enum.flat_map(&List.wrap/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    candidates =
      for entry <- entries,
          String.ends_with?(entry.name, ".png"),
          Path.dirname(entry.name) == app_dir,
          name = Path.basename(entry.name),
          Enum.any?(names, &String.starts_with?(name, &1)),
          do: entry

    with %Zip.Entry{} = entry <- Enum.max_by(candidates, & &1.size, fn -> nil end),
         {:ok, data} <- Zip.read_entry(reader, entry, @max_icon_size),
         {:ok, png} <- PNG.normalize(data) do
      png
    else
      _ -> nil
    end
  end

  defp find(entries, name), do: Enum.find(entries, &(&1.name == name))

  defp string(value) when is_binary(value), do: value
  defp string(_), do: nil

  defp date(%DateTime{} = date), do: DateTime.to_iso8601(date)
  defp date(_), do: nil
end
