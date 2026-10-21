defmodule BuildDistro.IPATest do
  use ExUnit.Case, async: true

  import Bitwise
  import BuildDistro.Fixtures

  alias BuildDistro.IPA
  alias BuildDistro.IPA.{Plist, PNG, Zip}

  defp reader(binary), do: fn offset, length -> {:ok, binary_part(binary, offset, length)} end

  describe "binary property lists" do
    test "decode every type Xcode writes" do
      {:ok, plist} = Plist.decode(File.read!(fixture_path("Info.plist")))

      assert plist["CFBundleIdentifier"] == "com.example.myapp"
      assert plist["CFBundleDisplayName"] == "My App ✓"
      assert plist["LSRequiresIPhoneOS"] == true
      assert plist["UIRequiredDeviceCapabilities"] == ["arm64"]
      assert plist["BuildMachineOSBuild"] == 25
      assert plist["Big"] == 9_000_000_000
      assert plist["Negative"] == -3
      assert plist["Ratio"] == 1.5
      assert plist["Built"] == ~U[2026-10-21 12:00:00.000000Z]
      assert plist["Blob"] == <<0, 1, 2>>

      assert get_in(plist, ["CFBundleIcons", "CFBundlePrimaryIcon", "CFBundleIconFiles"]) == [
               "AppIcon60x60"
             ]
    end

    test "reject damaged data instead of crashing" do
      data = File.read!(fixture_path("Info.plist"))
      assert {:error, _} = Plist.decode(binary_part(data, 0, 30))
      assert {:error, _} = Plist.decode("bplist00" <> :binary.copy(<<255>>, 64))
    end
  end

  test "the XML plist inside a signed profile is found and decoded" do
    {:ok, profile} = Plist.decode_profile(File.read!(fixture_path("embedded.mobileprovision")))

    assert profile["Name"] == "MyApp Ad Hoc"
    assert profile["ExpirationDate"] == ~U[2027-10-21 12:00:00Z]
    assert length(profile["ProvisionedDevices"]) == 2
    assert profile["Entitlements"]["get-task-allow"] == false
  end

  test "a crushed icon becomes a standard PNG with the same pixels" do
    {:ok, png} = PNG.normalize(File.read!(fixture_path("AppIcon60x60@2x.png")))

    refute png =~ "CgBI"
    assert pixels(png) == pixels(File.read!(fixture_path("AppIcon-source.png")))
  end

  test "standard PNGs pass through" do
    source = File.read!(fixture_path("AppIcon-source.png"))
    assert PNG.normalize(source) == {:ok, source}
  end

  describe "zip" do
    test "lists entries and reads stored and deflated ones" do
      ipa = ipa_fixture()
      {:ok, entries} = Zip.entries(reader(ipa), byte_size(ipa))

      info = Enum.find(entries, &(&1.name == "Payload/MyApp.app/Info.plist"))
      assert {:ok, data} = Zip.read_entry(reader(ipa), info, 1_000_000)
      assert data == File.read!(fixture_path("Info.plist"))
    end

    test "only reads the ranges it needs" do
      ipa = ipa_fixture(binary: :crypto.strong_rand_bytes(3_000_000))
      parent = self()

      counting_reader = fn offset, length ->
        send(parent, {:read, length})
        {:ok, binary_part(ipa, offset, length)}
      end

      {:ok, _} = IPA.inspect_ipa(counting_reader, byte_size(ipa))

      read =
        Stream.repeatedly(fn ->
          receive do
            {:read, n} -> n
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(& &1)
        |> Enum.sum()

      assert read < 200_000
    end

    test "refuses entries over the size limit" do
      ipa = ipa_fixture()
      {:ok, entries} = Zip.entries(reader(ipa), byte_size(ipa))
      binary = Enum.find(entries, &(&1.name == "Payload/MyApp.app/MyApp"))

      assert {:error, {:entry_too_large, _}} = Zip.read_entry(reader(ipa), binary, 100)
    end

    test "rejects files that aren't zips" do
      assert Zip.entries(reader("not a zip at all"), 16) == {:error, :not_a_zip}
    end
  end

  describe "inspecting an IPA" do
    test "reads identity, profile and icon" do
      ipa = ipa_fixture()
      {:ok, metadata} = IPA.inspect_ipa(reader(ipa), byte_size(ipa))

      assert metadata.bundle_id == "com.example.myapp"
      assert metadata.version == "1.4.0"
      assert metadata.build_version == "412"
      assert metadata.display_name == "My App ✓"
      assert metadata.minimum_os == "17.0"
      assert metadata.profile["kind"] == "ad-hoc"
      assert metadata.profile["device_count"] == 2
      assert metadata.profile["expires_at"] == "2027-10-21T12:00:00Z"
      assert <<0x89, "PNG", _::binary>> = metadata.icon
    end

    test "names what's wrong with an invalid upload" do
      assert {:error, {:invalid, _}} = IPA.inspect_ipa(reader("garbage"), 7)

      no_app = ipa_fixture(files: [{"README", "hi"}])
      assert {:error, {:invalid, message}} = IPA.inspect_ipa(reader(no_app), byte_size(no_app))
      assert message =~ "Info.plist"
    end

    test "a missing profile and icon don't fail the build" do
      ipa =
        ipa_fixture(
          files: [{"Payload/MyApp.app/Info.plist", File.read!(fixture_path("Info.plist"))}]
        )

      {:ok, metadata} = IPA.inspect_ipa(reader(ipa), byte_size(ipa))

      assert metadata.profile == nil
      assert metadata.icon == nil
    end
  end

  # Decodes RGBA pixels, undoing PNG row filters.
  defp pixels(png) do
    <<_::binary-8, rest::binary>> = png
    {width, data} = idat(rest, nil, [])
    raw = :zlib.uncompress(data)
    stride = width * 4
    row_size = stride + 1
    rows = for <<row::binary-size(^row_size) <- raw>>, do: row

    {decoded, _} =
      Enum.map_reduce(rows, :binary.copy(<<0>>, stride), fn <<filter, line::binary>>, previous ->
        row = unfilter(filter, line, previous)
        {row, row}
      end)

    IO.iodata_to_binary(decoded)
  end

  defp idat(
         <<length::32, type::binary-4, data::binary-size(length), _::32, rest::binary>>,
         width,
         acc
       ) do
    case type do
      "IHDR" ->
        <<w::32, _::binary>> = data
        idat(rest, w, acc)

      "IDAT" ->
        idat(rest, width, [acc, data])

      "IEND" ->
        {width, IO.iodata_to_binary(acc)}

      _ ->
        idat(rest, width, acc)
    end
  end

  defp unfilter(filter, line, previous) do
    line = :binary.bin_to_list(line)
    above = :binary.bin_to_list(previous)

    {out, _} =
      line
      |> Enum.zip(above)
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {{x, b}, i}, {out, _} ->
        a = if i >= 4, do: Enum.at(out, i - 4), else: 0
        c = if i >= 4, do: Enum.at(above, i - 4), else: 0

        value =
          case filter do
            0 -> x
            1 -> x + a
            2 -> x + b
            3 -> x + div(a + b, 2)
            4 -> x + paeth(a, b, c)
          end

        {out ++ [value &&& 0xFF], []}
      end)

    :binary.list_to_bin(out)
  end

  defp paeth(a, b, c) do
    p = a + b - c
    {pa, pb, pc} = {abs(p - a), abs(p - b), abs(p - c)}

    cond do
      pa <= pb and pa <= pc -> a
      pb <= pc -> b
      true -> c
    end
  end
end
