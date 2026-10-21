defmodule BuildDistro.IPA.Plist do
  @moduledoc """
  Property list decoding: binary (`bplist00`, as in an IPA's `Info.plist`) and
  XML (as in the CMS-wrapped `embedded.mobileprovision`).

  Dictionaries become maps, dates become `DateTime`, data stays binary.
  """

  import Bitwise

  @apple_epoch ~U[2001-01-01 00:00:00Z]
  @max_depth 64

  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  def decode("bplist00" <> _ = data), do: decode_binary(data)

  def decode(data) when is_binary(data) do
    if String.contains?(data, "<plist"), do: decode_xml(data), else: {:error, :not_a_plist}
  end

  @doc "Finds the XML property list inside a signed provisioning profile."
  @spec decode_profile(binary()) :: {:ok, map()} | {:error, term()}
  def decode_profile(data) do
    with [{start, _} | _] <- :binary.matches(data, "<?xml"),
         [_ | _] = ends <- :binary.matches(data, "</plist>"),
         {finish, length} <- List.last(ends),
         true <- finish > start do
      decode_xml(binary_part(data, start, finish + length - start))
    else
      _ -> {:error, :no_plist_in_profile}
    end
  end

  ## Binary

  defp decode_binary(data) when byte_size(data) < 40, do: {:error, :truncated_plist}

  defp decode_binary(data) do
    <<_::binary-6, offset_size, ref_size, count::64, top::64, table_offset::64>> =
      binary_part(data, byte_size(data) - 32, 32)

    if offset_size in 1..8 and ref_size in 1..8 and top < count and
         table_offset + count * offset_size <= byte_size(data) - 32 do
      offsets =
        for index <- 0..(count - 1)//1 do
          :binary.decode_unsigned(
            binary_part(data, table_offset + index * offset_size, offset_size)
          )
        end
        |> List.to_tuple()

      context = %{data: data, offsets: offsets, ref_size: ref_size}

      try do
        {:ok, object(context, top, 0)}
      rescue
        e in [ArgumentError, MatchError, FunctionClauseError] ->
          {:error, {:bad_binary_plist, Exception.message(e)}}
      end
    else
      {:error, :bad_binary_plist_trailer}
    end
  end

  defp object(_context, _ref, depth) when depth > @max_depth,
    do: raise(ArgumentError, "nesting too deep")

  defp object(context, ref, depth) do
    offset = elem(context.offsets, ref)
    <<marker, rest::binary>> = binary_part(context.data, offset, byte_size(context.data) - offset)
    decode_object(marker >>> 4, marker &&& 0x0F, rest, context, depth)
  end

  defp decode_object(0x0, 0x0, _, _, _), do: nil
  defp decode_object(0x0, 0x8, _, _, _), do: false
  defp decode_object(0x0, 0x9, _, _, _), do: true

  defp decode_object(0x1, power, rest, _, _) do
    size = 1 <<< power
    <<value::binary-size(^size), _::binary>> = rest

    # Integers shorter than 8 bytes are unsigned; 8 and 16 bytes are signed.
    if size < 8 do
      :binary.decode_unsigned(value)
    else
      bits = size * 8
      <<int::signed-size(^bits)>> = value
      int
    end
  end

  defp decode_object(0x2, 2, <<value::float-32, _::binary>>, _, _), do: value
  defp decode_object(0x2, 3, <<value::float-64, _::binary>>, _, _), do: value

  defp decode_object(0x3, 3, <<seconds::float-64, _::binary>>, _, _),
    do: DateTime.add(@apple_epoch, round(seconds * 1_000_000), :microsecond)

  defp decode_object(0x4, info, rest, _, _) do
    {length, rest} = length(info, rest)
    binary_part(rest, 0, length)
  end

  defp decode_object(0x5, info, rest, _, _) do
    {length, rest} = length(info, rest)
    binary_part(rest, 0, length)
  end

  defp decode_object(0x6, info, rest, _, _) do
    {length, rest} = length(info, rest)
    :unicode.characters_to_binary(binary_part(rest, 0, length * 2), {:utf16, :big})
  end

  defp decode_object(0x8, info, rest, _, _),
    do: {:uid, :binary.decode_unsigned(binary_part(rest, 0, info + 1))}

  defp decode_object(kind, info, rest, context, depth) when kind in [0xA, 0xC] do
    {length, rest} = length(info, rest)
    rest |> refs(length, context.ref_size) |> Enum.map(&object(context, &1, depth + 1))
  end

  defp decode_object(0xD, info, rest, context, depth) do
    {length, rest} = length(info, rest)
    refs = refs(rest, length * 2, context.ref_size)
    {keys, values} = Enum.split(refs, length)

    Enum.zip(keys, values)
    |> Map.new(fn {key, value} ->
      {object(context, key, depth + 1), object(context, value, depth + 1)}
    end)
  end

  defp decode_object(kind, _, _, _, _),
    do: raise(ArgumentError, "unsupported object type #{kind}")

  # A count of 15 means the real count follows as an integer object.
  defp length(0xF, <<marker, rest::binary>>) do
    0x1 = marker >>> 4
    size = 1 <<< (marker &&& 0x0F)
    bits = size * 8
    <<count::size(^bits), rest::binary>> = rest
    {count, rest}
  end

  defp length(info, rest), do: {info, rest}

  defp refs(data, count, ref_size) do
    for index <- 0..(count - 1)//1 do
      :binary.decode_unsigned(binary_part(data, index * ref_size, ref_size))
    end
  end

  ## XML

  defp decode_xml(xml) do
    # The DOCTYPE is dropped so xmerl neither fetches the DTD nor expands
    # entities declared in it.
    {document, _} =
      xml
      |> String.replace(~r/<!DOCTYPE[^\[>]*(\[[^\]]*\])?\s*>/, "")
      |> :binary.bin_to_list()
      |> :xmerl_scan.string(quiet: true, space: :preserve)

    case elements(document) do
      [root] -> {:ok, xml_value(root)}
      _ -> {:error, :bad_xml_plist}
    end
  catch
    :exit, _ -> {:error, :bad_xml_plist}
  end

  defp xml_value({:xmlElement, :dict, _, _, _, _, _, _, children, _, _, _}) do
    children
    |> elements()
    |> Enum.chunk_every(2)
    |> Map.new(fn [key, value] -> {text(key), xml_value(value)} end)
  end

  defp xml_value({:xmlElement, :array, _, _, _, _, _, _, children, _, _, _}),
    do: children |> elements() |> Enum.map(&xml_value/1)

  defp xml_value({:xmlElement, :string, _, _, _, _, _, _, _, _, _, _} = element),
    do: text(element)

  defp xml_value({:xmlElement, :integer, _, _, _, _, _, _, _, _, _, _} = element),
    do: element |> text() |> String.trim() |> String.to_integer()

  defp xml_value({:xmlElement, :real, _, _, _, _, _, _, _, _, _, _} = element) do
    {value, _} = element |> text() |> String.trim() |> Float.parse()
    value
  end

  defp xml_value({:xmlElement, true, _, _, _, _, _, _, _, _, _, _}), do: true
  defp xml_value({:xmlElement, false, _, _, _, _, _, _, _, _, _, _}), do: false

  defp xml_value({:xmlElement, :date, _, _, _, _, _, _, _, _, _, _} = element) do
    {:ok, date, _} = element |> text() |> String.trim() |> DateTime.from_iso8601()
    date
  end

  defp xml_value({:xmlElement, :data, _, _, _, _, _, _, _, _, _, _} = element),
    do: element |> text() |> String.replace(~r/\s+/, "") |> Base.decode64!()

  defp xml_value({:xmlElement, :plist, _, _, _, _, _, _, children, _, _, _}),
    do: children |> elements() |> hd() |> xml_value()

  defp elements({:xmlElement, :plist, _, _, _, _, _, _, _, _, _, _} = plist), do: [plist]

  defp elements(children) when is_list(children),
    do: Enum.filter(children, &(elem(&1, 0) == :xmlElement))

  defp text({:xmlElement, _, _, _, _, _, _, _, children, _, _, _}) do
    children
    |> Enum.filter(&(elem(&1, 0) == :xmlText))
    |> Enum.map(&elem(&1, 4))
    |> IO.chardata_to_string()
  end
end
